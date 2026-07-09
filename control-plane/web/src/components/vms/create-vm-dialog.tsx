"use client";

import { useState, useMemo, useCallback } from "react";
import Link from "next/link";
import { Loader2, HardDrive, FileText, AlertTriangle } from "lucide-react";
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
import { useOperationsStore } from "@/lib/stores/operations-store";
import { useProjectContext } from "@/providers";
import { toast } from "sonner";

interface CreateVMDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: () => void;
}

type SourceType = "image" | "template";

export function CreateVMDialog({
  open,
  onOpenChange,
  onCreated,
}: CreateVMDialogProps) {
  const watch = useOperationsStore((state) => state.watch);
  const [isLoading, setIsLoading] = useState(false);
  const [quotaError, setQuotaError] = useState<string | null>(null);
  const [sourceType, setSourceType] = useState<SourceType>("image");
  const [formData, setFormData] = useState({
    name: "",
    description: "",
    templateName: "ubuntu-22.04",
    imageId: "",
    cpu: "2",
    memory: "4",
    disk: "50",
    networkId: "",
    sshPublicKey: "",
  });

  // The VM is created in the project selected in the header switcher.
  const { currentProject } = useProjectContext();
  const projectId = currentProject?.id;
  const { data: images, isLoading: imagesLoading } = useImages(projectId);
  // The list always includes the global "default" network, so it is present
  // even when scoped to a project.
  const { data: networks = [] } = useNetworks(projectId);

  // Filter to only show ready images with valid IDs (memoized to prevent dependency changes on every render)
  const readyImages = useMemo(
    () => images?.filter((img) => img.status === "ready" && img.id) || [],
    [images]
  );

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

    if (sourceType === "image" && !formData.imageId) {
      toast.error("Please select an image");
      return;
    }

    if (sourceType === "template" && !formData.templateName.trim()) {
      toast.error("Please enter a template name");
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
        ...(sourceType === "image"
          ? { imageId: formData.imageId }
          : { templateName: formData.templateName }),
        cpu: parseInt(formData.cpu) || 2,
        memory: (parseInt(formData.memory) || 4) * GB,
        disk: (parseInt(formData.disk) || 50) * GB,
        ...(formData.networkId ? { networkId: formData.networkId } : {}),
        sshPublicKey: formData.sshPublicKey.trim() || undefined,
      });
      watch(operation, formData.name);
      toast.success(`Creating VM "${formData.name}"`);
      onOpenChange(false);
      onCreated?.();
      // Reset form
      setFormData({
        name: "",
        description: "",
        templateName: "ubuntu-22.04",
        imageId: "",
        cpu: "2",
        memory: "4",
        disk: "50",
        networkId: "",
        sshPublicKey: "",
      });
      setSourceType("image");
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

  const renderSourceSelector = () => {
    if (sourceType === "image") {
      return (
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
    }

    return (
      <div className="space-y-2">
        <Label htmlFor="template" className="text-foreground">
          OS Template (Legacy)
        </Label>
        <Input
          id="template"
          placeholder="ubuntu-22.04"
          value={formData.templateName}
          onChange={(e) =>
            setFormData({ ...formData, templateName: e.target.value })
          }
          className="bg-background border-border text-foreground"
          disabled={isLoading}
        />
        <p className="text-xs text-yellow-700">
          Templates are deprecated. Consider uploading an image instead.
        </p>
      </div>
    );
  };

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

            {/* Source Type Selector */}
            <div className="space-y-2">
              <Label className="text-foreground">Disk Source</Label>
              <div className="flex gap-2">
                <Button
                  type="button"
                  variant={sourceType === "image" ? "default" : "outline"}
                  size="sm"
                  onClick={() => setSourceType("image")}
                  className={
                    sourceType === "image"
                      ? "bg-primary hover:bg-primary/90"
                      : "border-input text-foreground/80 hover:bg-accent"
                  }
                  disabled={isLoading}
                >
                  <HardDrive className="h-4 w-4 mr-2" />
                  Image
                </Button>
                <Button
                  type="button"
                  variant={sourceType === "template" ? "default" : "outline"}
                  size="sm"
                  onClick={() => setSourceType("template")}
                  className={
                    sourceType === "template"
                      ? "bg-primary hover:bg-primary/90"
                      : "border-input text-foreground/80 hover:bg-accent"
                  }
                  disabled={isLoading}
                >
                  <FileText className="h-4 w-4 mr-2" />
                  Template
                </Button>
              </div>
            </div>

            {renderSourceSelector()}

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
