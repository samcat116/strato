"use client";

import { useMemo, useState } from "react";
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
import { volumesApi } from "@/lib/api/volumes";
import { useImages } from "@/lib/hooks/use-images";
import { useProjectContext } from "@/providers";
import { toast } from "sonner";
import type { VolumeFormat, VolumeType } from "@/types/api";

interface CreateVolumeDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: () => void;
}

const selectClassName =
  "w-full h-9 px-3 py-2 bg-gray-900 border border-gray-700 text-gray-100 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed";

export function CreateVolumeDialog({
  open,
  onOpenChange,
  onCreated,
}: CreateVolumeDialogProps) {
  const [isLoading, setIsLoading] = useState(false);
  const [formData, setFormData] = useState({
    name: "",
    description: "",
    sizeGB: "10",
    format: "qcow2" as VolumeFormat,
    volumeType: "data" as VolumeType,
    sourceImageId: "",
  });

  // The volume is created in the project selected in the header switcher.
  const { currentProject } = useProjectContext();
  const projectId = currentProject?.id;
  const { data: images, isLoading: imagesLoading } = useImages(projectId);

  const readyImages = useMemo(
    () => images?.filter((img) => img.status === "ready" && img.id) || [],
    [images]
  );

  const resetForm = () => {
    setFormData({
      name: "",
      description: "",
      sizeGB: "10",
      format: "qcow2",
      volumeType: "data",
      sourceImageId: "",
    });
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const name = formData.name.trim();
    if (!name) {
      toast.error("Please enter a volume name");
      return;
    }

    const sizeGB = parseInt(formData.sizeGB);
    if (!sizeGB || sizeGB < 1) {
      toast.error("Size must be at least 1 GB");
      return;
    }

    setIsLoading(true);
    try {
      await volumesApi.create({
        name,
        description: formData.description.trim() || undefined,
        projectId,
        sizeGB,
        format: formData.format,
        volumeType: formData.volumeType,
        sourceImageId: formData.sourceImageId || undefined,
      });
      toast.success(`Volume "${name}" is being created`);
      onOpenChange(false);
      onCreated?.();
      resetForm();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to create volume"
      );
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-gray-800 border-gray-700 text-gray-100">
        <DialogHeader>
          <DialogTitle>Create Volume</DialogTitle>
          <DialogDescription className="text-gray-400">
            {currentProject
              ? `Create a new volume in ${currentProject.name}`
              : "Create a new volume"}
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="volumeName" className="text-gray-200">
                Name
              </Label>
              <Input
                id="volumeName"
                placeholder="my-volume"
                value={formData.name}
                onChange={(e) =>
                  setFormData({ ...formData, name: e.target.value })
                }
                className="bg-gray-900 border-gray-700 text-gray-100"
                disabled={isLoading}
                autoFocus
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="volumeDescription" className="text-gray-200">
                Description
              </Label>
              <Input
                id="volumeDescription"
                placeholder="Data disk for my-vm"
                value={formData.description}
                onChange={(e) =>
                  setFormData({ ...formData, description: e.target.value })
                }
                className="bg-gray-900 border-gray-700 text-gray-100"
                disabled={isLoading}
              />
            </div>
            <div className="grid grid-cols-3 gap-4">
              <div className="space-y-2">
                <Label htmlFor="volumeSize" className="text-gray-200">
                  Size (GB)
                </Label>
                <Input
                  id="volumeSize"
                  type="number"
                  min="1"
                  value={formData.sizeGB}
                  onChange={(e) =>
                    setFormData({ ...formData, sizeGB: e.target.value })
                  }
                  className="bg-gray-900 border-gray-700 text-gray-100"
                  disabled={isLoading}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="volumeFormat" className="text-gray-200">
                  Format
                </Label>
                <select
                  id="volumeFormat"
                  value={formData.format}
                  onChange={(e) =>
                    setFormData({
                      ...formData,
                      format: e.target.value as VolumeFormat,
                    })
                  }
                  disabled={isLoading}
                  className={selectClassName}
                >
                  <option value="qcow2">qcow2</option>
                  <option value="raw">raw</option>
                </select>
              </div>
              <div className="space-y-2">
                <Label htmlFor="volumeType" className="text-gray-200">
                  Type
                </Label>
                <select
                  id="volumeType"
                  value={formData.volumeType}
                  onChange={(e) =>
                    setFormData({
                      ...formData,
                      volumeType: e.target.value as VolumeType,
                    })
                  }
                  disabled={isLoading}
                  className={selectClassName}
                >
                  <option value="data">Data</option>
                  <option value="boot">Boot</option>
                </select>
              </div>
            </div>
            <div className="space-y-2">
              <Label htmlFor="volumeSourceImage" className="text-gray-200">
                Source Image (optional)
              </Label>
              {imagesLoading ? (
                <div className="flex items-center gap-2 text-gray-400 text-sm">
                  <Loader2 className="h-4 w-4 animate-spin" />
                  Loading images...
                </div>
              ) : (
                <select
                  id="volumeSourceImage"
                  value={formData.sourceImageId}
                  onChange={(e) =>
                    setFormData({ ...formData, sourceImageId: e.target.value })
                  }
                  disabled={isLoading}
                  className={selectClassName}
                >
                  <option value="">None (empty volume)</option>
                  {readyImages.map((image) => (
                    <option key={image.id} value={image.id!}>
                      {image.name} ({image.sizeFormatted})
                    </option>
                  ))}
                </select>
              )}
              <p className="text-xs text-gray-500">
                Populate the volume from a disk image instead of starting
                empty.
              </p>
            </div>
          </div>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => onOpenChange(false)}
              className="border-gray-600 text-gray-300 hover:bg-gray-700"
              disabled={isLoading}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              className="bg-blue-600 hover:bg-blue-700"
              disabled={isLoading}
            >
              {isLoading ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Creating...
                </>
              ) : (
                "Create Volume"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
