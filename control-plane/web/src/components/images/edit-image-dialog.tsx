"use client";

import { useState } from "react";
import { Loader2 } from "lucide-react";
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
import { useUpdateImage } from "@/lib/hooks/use-images";
import { toast } from "sonner";
import type { CPUArchitecture, Image, UpdateImageRequest } from "@/types/api";

const BYTES_PER_GB = 1024 * 1024 * 1024;
const ARCHITECTURES: CPUArchitecture[] = ["x86_64", "arm64"];

function bytesToGBString(bytes: number | undefined): string {
  if (!bytes) return "";
  const gb = bytes / BYTES_PER_GB;
  // Trim float noise while keeping fractional sizes like 0.5 GB
  return String(Math.round(gb * 100) / 100);
}

interface EditImageDialogProps {
  image: Image;
  projectId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function EditImageDialog({
  image,
  projectId,
  open,
  onOpenChange,
}: EditImageDialogProps) {
  // Parents mount this dialog only while it is open, so state re-initializes
  // from the latest image data on every open.
  const [name, setName] = useState(image.name);
  const [description, setDescription] = useState(image.description ?? "");
  const [architecture, setArchitecture] = useState<CPUArchitecture>(
    image.architecture ?? "x86_64"
  );
  const [defaultCpu, setDefaultCpu] = useState(
    image.defaultCpu ? String(image.defaultCpu) : ""
  );
  const [defaultMemoryGB, setDefaultMemoryGB] = useState(
    bytesToGBString(image.defaultMemory)
  );
  const [defaultDiskGB, setDefaultDiskGB] = useState(
    bytesToGBString(image.defaultDisk)
  );
  const [defaultCmdline, setDefaultCmdline] = useState(
    image.defaultCmdline ?? ""
  );

  const updateImage = useUpdateImage(projectId);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!name.trim()) {
      toast.error("Image name is required");
      return;
    }

    const data: UpdateImageRequest = {
      name: name.trim(),
      description: description.trim(),
      architecture,
    };

    if (defaultCpu.trim()) {
      const cpu = parseInt(defaultCpu, 10);
      if (isNaN(cpu) || cpu < 1) {
        toast.error("Default CPU must be a positive number of cores");
        return;
      }
      data.defaultCpu = cpu;
    }
    if (defaultMemoryGB.trim()) {
      const gb = parseFloat(defaultMemoryGB);
      if (isNaN(gb) || gb <= 0) {
        toast.error("Default memory must be a positive size in GB");
        return;
      }
      data.defaultMemory = Math.round(gb * BYTES_PER_GB);
    }
    if (defaultDiskGB.trim()) {
      const gb = parseFloat(defaultDiskGB);
      if (isNaN(gb) || gb <= 0) {
        toast.error("Default disk must be a positive size in GB");
        return;
      }
      data.defaultDisk = Math.round(gb * BYTES_PER_GB);
    }
    if (defaultCmdline.trim()) {
      data.defaultCmdline = defaultCmdline.trim();
    }

    try {
      await updateImage.mutateAsync({ imageId: image.id!, data });
      toast.success(`Image "${name.trim()}" updated`);
      onOpenChange(false);
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to update image"
      );
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground sm:max-w-lg max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Edit Image</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Update the image name, description, and default VM settings.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="edit-image-name">Name</Label>
            <Input
              id="edit-image-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className="bg-muted border-input"
              disabled={updateImage.isPending}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="edit-image-description">Description</Label>
            <Input
              id="edit-image-description"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="A brief description of this image"
              className="bg-muted border-input"
              disabled={updateImage.isPending}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="edit-image-arch">Architecture</Label>
            <select
              id="edit-image-arch"
              value={architecture}
              onChange={(e) =>
                setArchitecture(e.target.value as CPUArchitecture)
              }
              className="w-full rounded-md bg-muted border border-input px-3 py-2 text-sm text-foreground"
              disabled={updateImage.isPending}
            >
              {ARCHITECTURES.map((arch) => (
                <option key={arch} value={arch}>
                  {arch}
                </option>
              ))}
            </select>
          </div>

          <div>
            <p className="text-sm font-medium text-foreground">
              Default VM Settings
            </p>
            <p className="text-xs text-muted-foreground mt-1">
              Pre-filled when creating a VM from this image. Leave a field
              blank to keep its current value.
            </p>
          </div>

          <div className="grid grid-cols-3 gap-3">
            <div className="space-y-2">
              <Label htmlFor="edit-image-cpu">CPU (cores)</Label>
              <Input
                id="edit-image-cpu"
                type="number"
                min="1"
                value={defaultCpu}
                onChange={(e) => setDefaultCpu(e.target.value)}
                placeholder="Not set"
                className="bg-muted border-input"
                disabled={updateImage.isPending}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="edit-image-memory">Memory (GB)</Label>
              <Input
                id="edit-image-memory"
                type="number"
                min="0.25"
                step="0.25"
                value={defaultMemoryGB}
                onChange={(e) => setDefaultMemoryGB(e.target.value)}
                placeholder="Not set"
                className="bg-muted border-input"
                disabled={updateImage.isPending}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="edit-image-disk">Disk (GB)</Label>
              <Input
                id="edit-image-disk"
                type="number"
                min="1"
                value={defaultDiskGB}
                onChange={(e) => setDefaultDiskGB(e.target.value)}
                placeholder="Not set"
                className="bg-muted border-input"
                disabled={updateImage.isPending}
              />
            </div>
          </div>

          <div className="space-y-2">
            <Label htmlFor="edit-image-cmdline">Kernel Command Line</Label>
            <Input
              id="edit-image-cmdline"
              value={defaultCmdline}
              onChange={(e) => setDefaultCmdline(e.target.value)}
              placeholder="e.g. console=ttyS0 root=/dev/vda1"
              className="bg-muted border-input font-mono"
              disabled={updateImage.isPending}
            />
          </div>

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              className="border-input"
              onClick={() => onOpenChange(false)}
              disabled={updateImage.isPending}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              className="bg-primary hover:bg-primary/90"
              disabled={updateImage.isPending}
            >
              {updateImage.isPending ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Saving...
                </>
              ) : (
                "Save Changes"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
