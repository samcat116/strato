"use client";

import { useState, useMemo, useCallback } from "react";
import Link from "next/link";
import { Loader2, AlertTriangle } from "lucide-react";
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
import {
  VMNetworkInterfacesFields,
  initialNIC,
  type NICRow,
} from "@/components/vms/create-vm-network-fields";
import { VMGuestOptionsFields } from "@/components/vms/create-vm-guest-options-fields";
import { VMImageSelector } from "@/components/vms/create-vm-image-selector";
import { vmsApi } from "@/lib/api/vms";
import { useAcceptedMutation } from "@/lib/hooks/use-accepted-mutation";
import { useImages } from "@/lib/hooks/use-images";
import { useNetworks } from "@/lib/hooks/use-networks";
import { useSecurityGroups } from "@/lib/hooks/use-security-groups";
import { useProjectContext, NO_PROJECT_DESCRIPTION } from "@/providers";
import type { MetadataSource } from "@/types/api";
import { toast } from "sonner";

interface CreateVMDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: () => void;
}


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

  const hasUserData = formData.userData.trim().length > 0;
  const hasFirecrackerMetadataNetwork = networkInterfaces.some((nic) => {
    const network = networks.find((candidate) => candidate.id === nic.networkId);
    return network?.metadataEnabled && network.dhcpEnabled;
  });

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

    // Firecracker has no seed disk: cloud-init reaches caller user data only
    // through MMDS after DHCP has configured at least one opted-in NIC. Mirror
    // the API guard here so the form explains an actionable configuration
    // error before submitting it.
    if (isFirecracker && hasUserData) {
      if (!metadataEnabled) {
        toast.error("Firecracker user data requires instance metadata");
        return;
      }
      if (!hasFirecrackerMetadataNetwork) {
        toast.error(
          "Firecracker user data requires a selected network with metadata and DHCP enabled"
        );
        return;
      }
    }

    setQuotaError(null);
    const GB = 1024 * 1024 * 1024; // 1 GiB in bytes; the API fields are named `memory`/`disk`
    const payload = {
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
      secureBoot: !isFirecracker && secureBoot,
      tpm: !isFirecracker && tpm,
      guestAgentEnabled: false,
      graphicsConsole: !isFirecracker && graphicsConsole,
      metadataEnabled,
      // Keep the selected source explicit so the request matches what the
      // form showed. Paths that cannot reach IMDS record `iso`.
      metadataSource: metadataSourceForcedToISO ? "iso" as const : metadataSource,
    };
    // Creation is asynchronous: the server accepts the request and returns the
    // VM with the generation it is converging on, which the MutationWatcher
    // follows and reports on completion.
    await run({
      intentKey: JSON.stringify(["POST", "/api/vms", payload]),
      request: (idempotencyKey) => vmsApi.create(payload, idempotencyKey),
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

            <VMImageSelector
              projectId={projectId}
              imagesLoading={imagesLoading}
              readyImages={readyImages}
              imageId={formData.imageId}
              isLoading={isLoading}
              onSelect={handleImageSelect}
            />

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

            <VMNetworkInterfacesFields
              isLoading={isLoading}
              networkInterfaces={networkInterfaces}
              setNetworkInterfaces={setNetworkInterfaces}
              networks={networks}
              securityGroups={securityGroups}
              securityGroupsFailed={securityGroupsFailed}
            />

            <VMGuestOptionsFields
              isLoading={isLoading}
              isFirecracker={isFirecracker}
              metadataEnabled={metadataEnabled}
              setMetadataEnabled={setMetadataEnabled}
              metadataSource={metadataSource}
              setMetadataSource={setMetadataSource}
              metadataSourceForcedToISO={metadataSourceForcedToISO}
              allSelectedNetworksDisableMetadata={allSelectedNetworksDisableMetadata}
              selectedImage={selectedImage}
              secureBoot={secureBoot}
              setSecureBoot={setSecureBoot}
              tpm={tpm}
              setTpm={setTpm}
              graphicsConsole={graphicsConsole}
              setGraphicsConsole={setGraphicsConsole}
              userData={formData.userData}
              onUserDataChange={(userData) =>
                setFormData({ ...formData, userData })
              }
            />
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
