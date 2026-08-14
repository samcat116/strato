"use client";

import { useState, useMemo, useCallback } from "react";
import Link from "next/link";
import { Loader2, AlertTriangle, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { vmsApi } from "@/lib/api/vms";
import { useAcceptedMutation } from "@/lib/hooks/use-accepted-mutation";
import { useImages } from "@/lib/hooks/use-images";
import { useNetworks } from "@/lib/hooks/use-networks";
import { useSecurityGroups } from "@/lib/hooks/use-security-groups";
import { useProjectContext, NO_PROJECT_DESCRIPTION } from "@/providers";
import { MAX_SECURITY_GROUPS_PER_NIC, type MetadataSource } from "@/types/api";
import { toast } from "sonner";

interface CreateVMDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: () => void;
}

interface NICRow {
  key: string;
  networkId: string;
  securityGroupIds: string[];
  mtu: string;
}

const initialNIC = (): NICRow => ({
  key: "nic-0",
  networkId: "",
  securityGroupIds: [],
  mtu: "",
});

export function CreateVMDialog({
  open,
  onOpenChange,
  onCreated,
}: CreateVMDialogProps) {
  const { isLoading, run } = useAcceptedMutation();
  const [quotaError, setQuotaError] = useState<string | null>(null);
  const [formData, setFormData] = useState({
    name: "",
    description: "",
    imageId: "",
    cpu: "2",
    memory: "4",
    disk: "50",
    sshPublicKey: "",
    userData: "",
  });
  // Machine profile (backend issue #565). Off by default: they cost a signed
  // firmware build and an swtpm process, and only Windows-class guests need them.
  const [secureBoot, setSecureBoot] = useState(false);
  const [tpm, setTpm] = useState(false);
  // Graphics console (backend issue #566). Off by default — headless is
  // cheaper, and most guests are reached over SSH — but it cannot be turned on
  // later, so this is the only chance to ask for it.
  const [graphicsConsole, setGraphicsConsole] = useState(false);
  // On by default: IMDS-backed bootstrap needs the listener, while ISO-backed
  // VMs can still use it as a guest metadata API.
  const [metadataEnabled, setMetadataEnabled] = useState(true);
  const [metadataSource, setMetadataSource] = useState<MetadataSource>("imds");
  const [networkInterfaces, setNetworkInterfaces] = useState<NICRow[]>([
    initialNIC(),
  ]);

  // The VM is created in the project selected in the header switcher.
  const { currentProject } = useProjectContext();
  const projectId = currentProject?.id;
  const { data: images, isLoading: imagesLoading } = useImages(projectId);
  // The list always includes the global "default" network, so it is present
  // even when scoped to a project.
  const { data: networks = [] } = useNetworks(projectId);
  const {
    data: securityGroups = [],
    isError: securityGroupsFailed,
  } = useSecurityGroups(projectId);

  const updateNIC = (key: string, update: Partial<NICRow>) => {
    setNetworkInterfaces((rows) =>
      rows.map((row) => (row.key === key ? { ...row, ...update } : row))
    );
  };

  const toggleSecurityGroup = (key: string, id: string) => {
    setNetworkInterfaces((rows) =>
      rows.map((row) =>
        row.key !== key
          ? row
          : {
              ...row,
              securityGroupIds: row.securityGroupIds.includes(id)
                ? row.securityGroupIds.filter((groupId) => groupId !== id)
                : [...row.securityGroupIds, id],
            }
      )
    );
  };

  // Filter to only show ready images with valid IDs (memoized to prevent dependency changes on every render)
  const readyImages = useMemo(
    () => images?.filter((img) => img.status === "ready" && img.id) || [],
    [images]
  );

  // The dialog never sends a hypervisor: the API infers one from the image's
  // artifact set when that set is compatible with exactly one, else QEMU.
  // Mirroring that inference here lets the firmware toggles disable themselves
  // instead of letting the create fail with a 400.
  const selectedImage = useMemo(
    () => readyImages.find((img) => img.id === formData.imageId),
    [readyImages, formData.imageId]
  );
  const isFirecracker = useMemo(() => {
    const compatible = selectedImage?.compatibleHypervisors ?? [];
    return compatible.length === 1 && compatible[0] === "firecracker";
  }, [selectedImage]);
  const allSelectedNetworksDisableMetadata = useMemo(
    () =>
      networkInterfaces.every((nic) => {
        const network = networks.find((candidate) => candidate.id === nic.networkId);
        return network !== undefined && !network.metadataEnabled;
      }),
    [networkInterfaces, networks]
  );
  const metadataSourceForcedToISO =
    isFirecracker || !metadataEnabled || allSelectedNetworksDisableMetadata;

  // Handle image selection - applies defaults directly without useEffect
  const handleImageSelect = useCallback(
    (imageId: string) => {
      const nextImage = readyImages.find((img) => img.id === imageId);
      if (nextImage) {
        const compatible = nextImage.compatibleHypervisors ?? [];
        setMetadataSource(
          !metadataEnabled ||
            nextImage.architecture === "arm64" ||
            (compatible.length === 1 && compatible[0] === "firecracker")
            ? "iso"
            : "imds"
        );
        setFormData((prev) => ({
          ...prev,
          imageId,
          cpu: nextImage.defaultCpu?.toString() || prev.cpu,
          memory: nextImage.defaultMemory?.toString() || prev.memory,
          disk: nextImage.defaultDisk?.toString() || prev.disk,
        }));
      } else {
        setFormData((prev) => ({ ...prev, imageId }));
      }
    },
    [readyImages, metadataEnabled]
  );

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    // Required: there is no default project to fall back to (issue #1059).
    // Without this the body would go out with the key dropped by
    // JSON.stringify and come back a 400 the user cannot act on.
    if (!projectId) {
      toast.error("Select a project first");
      return;
    }

    if (!formData.name.trim()) {
      toast.error("Please enter a VM name");
      return;
    }

    if (!formData.imageId) {
      toast.error("Please select an image");
      return;
    }

    if (networkInterfaces.some((nic) => !nic.networkId)) {
      toast.error("Select a network for every interface");
      return;
    }
    const invalidMTU = networkInterfaces.find((nic) => {
      if (!nic.mtu) return false;
      const mtu = Number(nic.mtu);
      return !Number.isInteger(mtu) || mtu < 68 || mtu > 65535;
    });
    if (invalidMTU) {
      toast.error("MTU must be a whole number from 68 to 65535");
      return;
    }

    setQuotaError(null);
    const GB = 1024 * 1024 * 1024; // 1 GiB in bytes; the API fields are named `memory`/`disk`
    // Creation is asynchronous: the server accepts the request and returns the
    // VM with the generation it is converging on, which the MutationWatcher
    // follows and reports on completion.
    await run({
      request: () =>
        vmsApi.create({
          name: formData.name,
          description: formData.description || undefined,
          projectId,
          imageId: formData.imageId,
          cpu: parseInt(formData.cpu) || 2,
          memory: (parseInt(formData.memory) || 4) * GB,
          disk: (parseInt(formData.disk) || 50) * GB,
          networkInterfaces: networkInterfaces.map((nic) => ({
            networkId: nic.networkId,
            securityGroupIds:
              nic.securityGroupIds.length > 0
                ? nic.securityGroupIds
                : undefined,
            mtu: nic.mtu ? Number(nic.mtu) : undefined,
          })),
          sshPublicKey: formData.sshPublicKey.trim() || undefined,
          // Sent verbatim (no trim): the first bytes are the format header
          // cloud-init dispatches on.
          userData: formData.userData.trim() ? formData.userData : undefined,
          // Omitted unless on, so pre-#565 control planes ignore them harmlessly.
          // Never sent for Firecracker, which the API rejects outright.
          secureBoot: !isFirecracker && secureBoot ? true : undefined,
          tpm: !isFirecracker && tpm ? true : undefined,
          // Same omit-unless-on rule (issue #566); Firecracker emulates no
          // display device and the API rejects the combination.
          graphicsConsole: !isFirecracker && graphicsConsole ? true : undefined,
          // Omitted unless *off*, the inverse of the three above, because this
          // one defaults on: sending `true` would only say what the server
          // already assumes, while pinning a pre-STR-185 control plane to a key
          // it does not know.
          metadataEnabled: metadataEnabled ? undefined : false,
          // Keep the selected source explicit so the request matches what the
          // form showed. Paths that cannot reach IMDS record `iso`.
          metadataSource: metadataSourceForcedToISO ? "iso" : metadataSource,
        }),
      watch: {
        kind: "create",
        resourceKind: "virtual_machine",
        resourceName: formData.name,
      },
      errorMessage: "Failed to create VM",
      successMessage: `Creating VM "${formData.name}"`,
      onSuccess: () => {
        onOpenChange(false);
        onCreated?.();
        // Reset form
        setFormData({
          name: "",
          description: "",
          imageId: "",
          cpu: "2",
          memory: "4",
          disk: "50",
          sshPublicKey: "",
          userData: "",
        });
        setSecureBoot(false);
        setTpm(false);
        setGraphicsConsole(false);
        setMetadataEnabled(true);
        setMetadataSource("imds");
        setNetworkInterfaces([initialNIC()]);
        setQuotaError(null);
      },
      // Quota rejections surface inline with a pointer to the quotas page,
      // since resolving them means editing a quota rather than the VM form.
      onError: (message) => {
        if (/quota/i.test(message)) {
          setQuotaError(message);
          return true;
        }
        return false;
      },
    });
  };

  const renderImageSelector = () => (
    <div className="space-y-2">
      <Label htmlFor="image" className="text-foreground">
        Disk Image
      </Label>
      {!projectId ? (
        <div className="text-sm text-muted-foreground py-2">
          No project available. Create a project first to upload images.
        </div>
      ) : imagesLoading ? (
        <div className="flex items-center gap-2 text-muted-foreground text-sm">
          <Loader2 className="h-4 w-4 animate-spin" />
          Loading images...
        </div>
      ) : readyImages.length === 0 ? (
        <div className="text-sm text-muted-foreground py-2">
          No images available.{" "}
          <a href="/images" className="text-blue-600 hover:underline">
            Upload an image
          </a>{" "}
          first.
        </div>
      ) : (
        <select
          value={formData.imageId}
          onChange={(e) => handleImageSelect(e.target.value)}
          disabled={isLoading}
          className="w-full h-9 px-3 py-2 bg-background border border-border text-foreground rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed"
        >
          <option value="" disabled>
            Select an image
          </option>
          {readyImages.map((image) => (
            <option key={image.id} value={image.id!}>
              {image.name}
              {image.sizeFormatted ? ` (${image.sizeFormatted})` : ""}
            </option>
          ))}
        </select>
      )}
    </div>
  );

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground sm:max-w-2xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Create Virtual Machine</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            {currentProject
              ? `Configure your new virtual machine in ${currentProject.name}`
              : NO_PROJECT_DESCRIPTION}
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            {quotaError && (
              <div className="flex items-start gap-2 rounded-md border border-red-500/40 bg-red-500/10 p-3 text-sm text-red-700">
                <AlertTriangle className="h-4 w-4 mt-0.5 shrink-0" />
                <div className="space-y-1">
                  <p>{quotaError}</p>
                  <Link
                    href="/quotas"
                    className="inline-block font-medium text-red-800 underline hover:text-red-800"
                  >
                    Review resource quotas
                  </Link>
                </div>
              </div>
            )}
            <div className="space-y-2">
              <Label htmlFor="name" className="text-foreground">
                VM Name
              </Label>
              <Input
                id="name"
                placeholder="my-vm"
                value={formData.name}
                onChange={(e) =>
                  setFormData({ ...formData, name: e.target.value })
                }
                className="bg-background border-border text-foreground"
                disabled={isLoading}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="description" className="text-foreground">
                Description
              </Label>
              <Input
                id="description"
                placeholder="Production web server"
                value={formData.description}
                onChange={(e) =>
                  setFormData({ ...formData, description: e.target.value })
                }
                className="bg-background border-border text-foreground"
                disabled={isLoading}
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="sshPublicKey" className="text-foreground">
                SSH Public Key{" "}
                <span className="text-muted-foreground">(optional)</span>
              </Label>
              <Input
                id="sshPublicKey"
                placeholder="ssh-ed25519 AAAA... user@host"
                value={formData.sshPublicKey}
                onChange={(e) =>
                  setFormData({ ...formData, sshPublicKey: e.target.value })
                }
                className="bg-background border-border text-foreground font-mono text-xs"
                disabled={isLoading}
              />
              <p className="text-xs text-muted-foreground">
                Authorized for the guest&apos;s default user via cloud-init.
                Leave blank for no SSH login.
              </p>
            </div>

            {renderImageSelector()}

            <div className="grid grid-cols-3 gap-4">
              <div className="space-y-2">
                <Label htmlFor="cpu" className="text-foreground">
                  CPU Cores
                </Label>
                <Input
                  id="cpu"
                  type="number"
                  min="1"
                  value={formData.cpu}
                  onChange={(e) =>
                    setFormData({ ...formData, cpu: e.target.value })
                  }
                  className="bg-background border-border text-foreground"
                  disabled={isLoading}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="memory" className="text-foreground">
                  Memory (GiB)
                </Label>
                <Input
                  id="memory"
                  type="number"
                  min="1"
                  value={formData.memory}
                  onChange={(e) =>
                    setFormData({ ...formData, memory: e.target.value })
                  }
                  className="bg-background border-border text-foreground"
                  disabled={isLoading}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="disk" className="text-foreground">
                  Disk (GiB)
                </Label>
                <Input
                  id="disk"
                  type="number"
                  min="10"
                  value={formData.disk}
                  onChange={(e) =>
                    setFormData({ ...formData, disk: e.target.value })
                  }
                  className="bg-background border-border text-foreground"
                  disabled={isLoading}
                />
              </div>
            </div>

            <div className="space-y-3">
              <div className="flex items-center justify-between">
                <div>
                  <Label className="text-foreground">Network interfaces</Label>
                  <p className="text-xs text-muted-foreground">
                    Add up to eight NICs. Duplicate network selections are allowed.
                  </p>
                </div>
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={isLoading || networkInterfaces.length >= 8}
                  onClick={() =>
                    setNetworkInterfaces((rows) => [
                      ...rows,
                      {
                        ...initialNIC(),
                        key: crypto.randomUUID(),
                      },
                    ])
                  }
                >
                  <Plus className="mr-1 h-4 w-4" /> Add NIC
                </Button>
              </div>

              {networkInterfaces.map((nic, index) => (
                <div
                  key={nic.key}
                  className="space-y-3 rounded-md border border-border p-3"
                >
                  <div className="flex items-center justify-between">
                    <span className="text-sm font-medium">net{index}</span>
                    <Button
                      type="button"
                      size="sm"
                      variant="ghost"
                      aria-label={`Remove net${index}`}
                      disabled={isLoading || networkInterfaces.length === 1}
                      onClick={() =>
                        setNetworkInterfaces((rows) =>
                          rows.filter((row) => row.key !== nic.key)
                        )
                      }
                    >
                      <Trash2 className="h-4 w-4 text-red-600" />
                    </Button>
                  </div>
                  <div className="grid gap-3 sm:grid-cols-[1fr_9rem]">
                    <div className="space-y-1">
                      <Label htmlFor={`network-${nic.key}`}>Network</Label>
                      <select
                        id={`network-${nic.key}`}
                        value={nic.networkId}
                        onChange={(event) =>
                          updateNIC(nic.key, { networkId: event.target.value })
                        }
                        disabled={isLoading || networks.length === 0}
                        required
                        className="w-full h-9 px-3 py-2 bg-background border border-border text-foreground rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:opacity-50"
                      >
                        <option value="" disabled>Select a network</option>
                        {networks.filter((network) => network.id).map((network) => (
                          <option key={network.id} value={network.id!}>
                            {network.name} ({network.subnet})
                          </option>
                        ))}
                      </select>
                    </div>
                    <div className="space-y-1">
                      <Label htmlFor={`mtu-${nic.key}`}>MTU (optional)</Label>
                      <Input
                        id={`mtu-${nic.key}`}
                        type="number"
                        min="68"
                        max="65535"
                        placeholder="Network default"
                        value={nic.mtu}
                        onChange={(event) =>
                          updateNIC(nic.key, { mtu: event.target.value })
                        }
                        disabled={isLoading}
                      />
                    </div>
                  </div>
                  {securityGroups.length > 0 && (
                    <div className="space-y-1">
                      <Label>Security groups</Label>
                      <div className="grid gap-1 rounded-md border border-border p-2 sm:grid-cols-2">
                        {securityGroups.map((group) => {
                          const checked = nic.securityGroupIds.includes(group.id);
                          const atLimit =
                            !checked &&
                            nic.securityGroupIds.length >= MAX_SECURITY_GROUPS_PER_NIC;
                          return (
                            <label key={group.id} className="flex items-center gap-2 text-sm">
                              <input
                                type="checkbox"
                                checked={checked}
                                onChange={() => toggleSecurityGroup(nic.key, group.id)}
                                disabled={isLoading || atLimit}
                                className="h-4 w-4 rounded border-input bg-background accent-blue-600"
                              />
                              <span className="truncate">{group.name}</span>
                            </label>
                          );
                        })}
                      </div>
                      <p className="text-xs text-muted-foreground">
                        Default group is used when none are selected.
                      </p>
                    </div>
                  )}
                </div>
              ))}
              {networks.length === 0 && (
                <p className="text-xs text-muted-foreground">
                  This project has no networks yet. Create one before adding a VM.
                </p>
              )}
            </div>
            {securityGroupsFailed && (
              // A failed fetch must not read as "this project has no groups":
              // the VM would silently land on the default group only.
              <p className="text-xs text-red-600">
                Failed to load security groups — the VM will use the
                project&apos;s default group. Retry from the Security Groups
                page.
              </p>
            )}

            <div className="space-y-3 rounded-md border border-border p-3">
              <div className="space-y-1">
                <Label htmlFor="metadataSource" className="text-foreground">
                  Guest bootstrap source
                </Label>
                <p className="text-xs text-muted-foreground">
                  Choose where cloud-init reads hostname, SSH keys, and user
                  data at first boot.
                </p>
              </div>
              <select
                id="metadataSource"
                value={metadataSourceForcedToISO ? "iso" : metadataSource}
                onChange={(e) =>
                  setMetadataSource(e.target.value as MetadataSource)
                }
                disabled={isLoading || metadataSourceForcedToISO}
                className="w-full px-3 py-2 bg-background border border-input text-foreground rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <option value="imds">
                  Instance metadata service (x86 QEMU default)
                </option>
                <option value="iso">Seed ISO</option>
              </select>
              {isFirecracker ? (
                <p className="text-xs text-muted-foreground">
                  Firecracker does not have a cloud-init bootstrap path, so an
                  IMDS-backed seed is unavailable for this image.
                </p>
              ) : !metadataEnabled ? (
                <p className="text-xs text-muted-foreground">
                  IMDS bootstrap requires the instance metadata service. Seed
                  ISO will be used while the service is disabled.
                </p>
              ) : allSelectedNetworksDisableMetadata ? (
                <p className="text-xs text-muted-foreground">
                  None of the selected networks publish instance metadata. Seed
                  ISO will be used for this VM.
                </p>
              ) : selectedImage?.architecture === "arm64" &&
                metadataSource === "iso" ? (
                <p className="text-xs text-muted-foreground">
                  ARM64 QEMU defaults to Seed ISO until it has an equivalent
                  NoCloudNet discovery hint.
                </p>
              ) : metadataSource === "imds" ? (
                <p className="text-xs text-muted-foreground">
                  The ISO keeps the network configuration needed to get online,
                  then follows a <code>seedfrom</code> stub to
                  169.254.169.254 for the remaining, mutable documents.
                </p>
              ) : (
                <p className="text-xs text-muted-foreground">
                  The complete, immutable NoCloud payload is written to the ISO.
                  Use this compatibility path when the guest cannot use IMDS.
                </p>
              )}
            </div>

            <div className="space-y-3 rounded-md border border-border p-3">
              <div className="space-y-1">
                <p className="text-sm font-medium text-foreground">
                  Windows / Secure Boot
                </p>
                <p className="text-xs text-muted-foreground">
                  Windows 11 and Server 2025 require both. Leave off for Linux
                  guests.
                </p>
              </div>
              <label className="flex items-center gap-2 text-sm text-foreground">
                <input
                  id="secureBoot"
                  type="checkbox"
                  checked={!isFirecracker && secureBoot}
                  onChange={(e) => setSecureBoot(e.target.checked)}
                  disabled={isLoading || isFirecracker}
                  className="h-4 w-4 rounded border-input bg-background accent-blue-600"
                />
                Secure Boot
              </label>
              <label className="flex items-center gap-2 text-sm text-foreground">
                <input
                  id="tpm"
                  type="checkbox"
                  checked={!isFirecracker && tpm}
                  onChange={(e) => setTpm(e.target.checked)}
                  disabled={isLoading || isFirecracker}
                  className="h-4 w-4 rounded border-input bg-background accent-blue-600"
                />
                TPM 2.0
              </label>
              {isFirecracker ? (
                <p className="text-xs text-muted-foreground">
                  Unavailable for this image: it boots under Firecracker, which
                  has no UEFI firmware or TPM device. Use a QEMU image.
                </p>
              ) : (
                <p className="text-xs text-muted-foreground">
                  Secure Boot boots signed firmware with Microsoft&apos;s keys
                  enrolled. TPM 2.0 is emulated per VM and only places on nodes
                  with <code>swtpm</code> installed.
                </p>
              )}
            </div>

            <div className="space-y-3 rounded-md border border-border p-3">
              <div className="space-y-1">
                <p className="text-sm font-medium text-foreground">Display</p>
                <p className="text-xs text-muted-foreground">
                  Needed to run a graphical OS installer, or to reach a guest
                  that never brings up a network.
                </p>
              </div>
              <label className="flex items-center gap-2 text-sm text-foreground">
                <input
                  id="graphicsConsole"
                  type="checkbox"
                  checked={!isFirecracker && graphicsConsole}
                  onChange={(e) => setGraphicsConsole(e.target.checked)}
                  disabled={isLoading || isFirecracker}
                  className="h-4 w-4 rounded border-input bg-background accent-blue-600"
                />
                Graphics console
              </label>
              {isFirecracker ? (
                <p className="text-xs text-muted-foreground">
                  Unavailable for this image: it boots under Firecracker, which
                  emulates no display device. Use a QEMU image.
                </p>
              ) : (
                <p className="text-xs text-muted-foreground">
                  Adds a virtual display and a VNC server, shown in the VM&apos;s
                  Display tab. <strong>This cannot be changed later</strong> —
                  the display is fixed when the VM is created. The serial console
                  works either way.
                </p>
              )}
            </div>

            <div className="space-y-3 rounded-md border border-border p-3">
              <div className="space-y-1">
                <p className="text-sm font-medium text-foreground">
                  Instance metadata
                </p>
                <p className="text-xs text-muted-foreground">
                  The link-local service at 169.254.169.254 that a guest reads
                  its own configuration and identity from.
                </p>
              </div>
              <label className="flex items-center gap-2 text-sm text-foreground">
                <input
                  id="metadataEnabled"
                  type="checkbox"
                  checked={metadataEnabled}
                  onChange={(e) => {
                    const enabled = e.target.checked;
                    setMetadataEnabled(enabled);
                    if (!enabled) setMetadataSource("iso");
                  }}
                  disabled={isLoading}
                  className="h-4 w-4 rounded border-input bg-background accent-blue-600"
                />
                Serve instance metadata to this VM
              </label>
              <p className="text-xs text-muted-foreground">
                Turning it off denies this VM the service outright, even where
                its security groups would allow it — the lever for a workload
                you want an SSRF bug to find nothing behind.{" "}
                If the guest bootstrap source above is instance metadata,
                turning this off also prevents cloud-init from fetching its
                configuration. This switch can be changed later.
              </p>
            </div>

            <div className="space-y-2">
              <Label htmlFor="userData" className="text-foreground">
                Cloud-init user data{" "}
                <span className="text-muted-foreground">(optional)</span>
              </Label>
              <textarea
                id="userData"
                placeholder={"#cloud-config\npackages:\n  - nginx\nruncmd:\n  - systemctl enable --now nginx"}
                value={formData.userData}
                onChange={(e) =>
                  setFormData({ ...formData, userData: e.target.value })
                }
                rows={5}
                spellCheck={false}
                disabled={isLoading}
                className="w-full px-3 py-2 bg-background border border-border text-foreground rounded-md font-mono text-xs focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed resize-y"
              />
              <p className="text-xs text-muted-foreground">
                Runs in the guest at first boot. Accepts any cloud-init format:{" "}
                <code>#cloud-config</code>, a <code>#!</code> shell script,{" "}
                <code>#include</code>, a Jinja template, or a full MIME
                multipart document.
              </p>
            </div>
          </div>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => {
                setQuotaError(null);
                onOpenChange(false);
              }}
              className="border-input text-foreground/80 hover:bg-accent"
              disabled={isLoading}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              className="bg-primary hover:bg-primary/90"
              disabled={isLoading || !projectId}
            >
              {isLoading ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Creating...
                </>
              ) : (
                "Create VM"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
