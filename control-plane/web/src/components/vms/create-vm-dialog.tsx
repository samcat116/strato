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
import { vmsApi } from "@/lib/api/vms";
import { useImages } from "@/lib/hooks/use-images";
import { useNetworks } from "@/lib/hooks/use-networks";
import { useSecurityGroups } from "@/lib/hooks/use-security-groups";
import { useOperationsStore } from "@/lib/stores/operations-store";
import { useProjectContext } from "@/providers";
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
  const watch = useOperationsStore((state) => state.watch);
  const [isLoading, setIsLoading] = useState(false);
  const [quotaError, setQuotaError] = useState<string | null>(null);
  const [formData, setFormData] = useState({
    name: "",
    description: "",
    imageId: "",
    cpu: "2",
    memory: "4",
    disk: "50",
    networkId: "",
    sshPublicKey: "",
    userData: "",
  });
  // Machine profile (backend issue #565). Off by default: they cost a signed
  // firmware build and an swtpm process, and only Windows-class guests need them.
  const [secureBoot, setSecureBoot] = useState(false);
  const [tpm, setTpm] = useState(false);
  // Security groups for the VM's NIC (max 5). Empty → the server falls back
  // to the project's default group.
  const [securityGroupIds, setSecurityGroupIds] = useState<string[]>([]);

  // The VM is created in the project selected in the header switcher.
  const { currentProject } = useProjectContext();
  const projectId = currentProject?.id;
  const { data: images, isLoading: imagesLoading } = useImages(projectId);
  // The list always includes the global "default" network, so it is present
  // even when scoped to a project.
  const { data: networks = [] } = useNetworks(projectId);
  const { data: securityGroups = [] } = useSecurityGroups(projectId);

  const toggleSecurityGroup = (id: string) => {
    setSecurityGroupIds((prev) =>
      prev.includes(id) ? prev.filter((g) => g !== id) : [...prev, id]
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
  const isFirecracker = useMemo(() => {
    const selected = readyImages.find((img) => img.id === formData.imageId);
    const compatible = selected?.compatibleHypervisors ?? [];
    return compatible.length === 1 && compatible[0] === "firecracker";
  }, [readyImages, formData.imageId]);

  // Handle image selection - applies defaults directly without useEffect
  const handleImageSelect = useCallback(
    (imageId: string) => {
      const selectedImage = readyImages.find((img) => img.id === imageId);
      if (selectedImage) {
        setFormData((prev) => ({
          ...prev,
          imageId,
          cpu: selectedImage.defaultCpu?.toString() || prev.cpu,
          memory: selectedImage.defaultMemory?.toString() || prev.memory,
          disk: selectedImage.defaultDisk?.toString() || prev.disk,
        }));
      } else {
        setFormData((prev) => ({ ...prev, imageId }));
      }
    },
    [readyImages]
  );

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!formData.name.trim()) {
      toast.error("Please enter a VM name");
      return;
    }

    if (!formData.imageId) {
      toast.error("Please select an image");
      return;
    }

    setIsLoading(true);
    setQuotaError(null);
    try {
      const GB = 1024 * 1024 * 1024; // 1 GB in bytes
      // Creation is asynchronous: the server accepts the request and returns an
      // operation, which the OperationWatcher polls and reports on completion.
      const operation = await vmsApi.create({
        name: formData.name,
        description: formData.description || undefined,
        projectId,
        imageId: formData.imageId,
        cpu: parseInt(formData.cpu) || 2,
        memory: (parseInt(formData.memory) || 4) * GB,
        disk: (parseInt(formData.disk) || 50) * GB,
        ...(formData.networkId ? { networkId: formData.networkId } : {}),
        sshPublicKey: formData.sshPublicKey.trim() || undefined,
        // Sent verbatim (no trim): the first bytes are the format header
        // cloud-init dispatches on.
        userData: formData.userData.trim() ? formData.userData : undefined,
        // Omitted unless on, so pre-#565 control planes ignore them harmlessly.
        // Never sent for Firecracker, which the API rejects outright.
        secureBoot: !isFirecracker && secureBoot ? true : undefined,
        tpm: !isFirecracker && tpm ? true : undefined,
        // Omitted when empty → the server uses the project's default group.
        securityGroupIds:
          securityGroupIds.length > 0 ? securityGroupIds : undefined,
      });
      watch(operation, formData.name);
      toast.success(`Creating VM "${formData.name}"`);
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
        networkId: "",
        sshPublicKey: "",
        userData: "",
      });
      setSecureBoot(false);
      setTpm(false);
      setSecurityGroupIds([]);
      setQuotaError(null);
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Failed to create VM";
      // Quota rejections surface inline with a pointer to the quotas page,
      // since resolving them means editing a quota rather than the VM form.
      if (/quota/i.test(message)) {
        setQuotaError(message);
      } else {
        toast.error(message);
      }
    } finally {
      setIsLoading(false);
    }
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
              {image.name} ({image.sizeFormatted})
            </option>
          ))}
        </select>
      )}
    </div>
  );

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>Create Virtual Machine</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Configure your new virtual machine
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
                  Memory (GB)
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
                  Disk (GB)
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

            <div className="space-y-2">
              <Label htmlFor="network" className="text-foreground">
                Network
              </Label>
              <select
                id="network"
                value={formData.networkId}
                onChange={(e) =>
                  setFormData({ ...formData, networkId: e.target.value })
                }
                disabled={isLoading}
                className="w-full h-9 px-3 py-2 bg-background border border-border text-foreground rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <option value="">default (auto)</option>
                {networks
                  .filter((network) => network.id && !network.isDefault)
                  .map((network) => (
                    <option key={network.id} value={network.id!}>
                      {network.name} ({network.subnet})
                    </option>
                  ))}
              </select>
              <p className="text-xs text-muted-foreground">
                The VM&apos;s IP is allocated automatically from the selected
                network.
              </p>
            </div>

            {securityGroups.length > 0 && (
              <div className="space-y-2">
                <Label className="text-foreground">Security Groups</Label>
                <div className="space-y-1 rounded-md border border-border p-3 max-h-36 overflow-y-auto">
                  {securityGroups.map((group) => {
                    const checked = securityGroupIds.includes(group.id);
                    // NICs attach at most 5 groups; block checking a sixth.
                    const atLimit = !checked && securityGroupIds.length >= 5;
                    return (
                      <label
                        key={group.id}
                        className="flex items-center gap-2 text-sm text-foreground"
                      >
                        <input
                          type="checkbox"
                          checked={checked}
                          onChange={() => toggleSecurityGroup(group.id)}
                          disabled={isLoading || atLimit}
                          className="h-4 w-4 rounded border-input bg-background accent-blue-600"
                        />
                        {group.name}
                        {group.description && (
                          <span className="text-xs text-muted-foreground truncate">
                            {group.description}
                          </span>
                        )}
                      </label>
                    );
                  })}
                </div>
                <p className="text-xs text-muted-foreground">
                  Default group is used when none selected. A NIC can attach up
                  to 5 groups.
                </p>
              </div>
            )}

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
              disabled={isLoading}
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
