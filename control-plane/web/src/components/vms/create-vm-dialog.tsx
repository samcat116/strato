"use client";

import { useState, useEffect } from "react";
import { Loader2, HardDrive, FileText } from "lucide-react";
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
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { vmsApi } from "@/lib/api/vms";
import { useImages } from "@/lib/hooks/use-images";
import { useProjectsForOrganization } from "@/lib/hooks/use-projects";
import { useOrganization } from "@/providers/organization-provider";
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
  const [isLoading, setIsLoading] = useState(false);
  const [sourceType, setSourceType] = useState<SourceType>("image");
  const [formData, setFormData] = useState({
    name: "",
    description: "",
    templateName: "ubuntu-22.04",
    imageId: "",
    cpu: "2",
    memory: "4",
    disk: "50",
  });

  // Get current organization and its projects
  const { currentOrg } = useOrganization();
  const { data: projects } = useProjectsForOrganization(currentOrg?.id);

  // Use the first project's ID if available
  const projectId = projects?.[0]?.id;
  const { data: images, isLoading: imagesLoading } = useImages(projectId);

  // Filter to only show ready images
  const readyImages = images?.filter((img) => img.status === "ready") || [];

  // Apply image defaults when an image is selected
  useEffect(() => {
    if (sourceType === "image" && formData.imageId) {
      const selectedImage = readyImages.find(
        (img) => img.id === formData.imageId
      );
      if (selectedImage) {
        setFormData((prev) => ({
          ...prev,
          cpu: selectedImage.defaultCpu?.toString() || prev.cpu,
          memory: selectedImage.defaultMemory?.toString() || prev.memory,
          disk: selectedImage.defaultDisk?.toString() || prev.disk,
        }));
      }
    }
  }, [formData.imageId, sourceType, readyImages]);

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
    try {
      const GB = 1024 * 1024 * 1024; // 1 GB in bytes
      await vmsApi.create({
        name: formData.name,
        description: formData.description || undefined,
        ...(sourceType === "image"
          ? { imageId: formData.imageId }
          : { templateName: formData.templateName }),
        cpu: parseInt(formData.cpu) || 2,
        memory: (parseInt(formData.memory) || 4) * GB,
        disk: (parseInt(formData.disk) || 50) * GB,
      });
      toast.success(`VM "${formData.name}" created successfully`);
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
      });
      setSourceType("image");
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to create VM"
      );
    } finally {
      setIsLoading(false);
    }
  };

  const renderSourceSelector = () => {
    if (sourceType === "image") {
      return (
        <div className="space-y-2">
          <Label htmlFor="image" className="text-gray-200">
            Disk Image
          </Label>
          {!projectId ? (
            <div className="text-sm text-gray-400 py-2">
              No project available. Create a project first to upload images.
            </div>
          ) : imagesLoading ? (
            <div className="flex items-center gap-2 text-gray-400 text-sm">
              <Loader2 className="h-4 w-4 animate-spin" />
              Loading images...
            </div>
          ) : readyImages.length === 0 ? (
            <div className="text-sm text-gray-400 py-2">
              No images available.{" "}
              <a href="/images" className="text-blue-400 hover:underline">
                Upload an image
              </a>{" "}
              first.
            </div>
          ) : (
            <Select
              value={formData.imageId}
              onValueChange={(value) =>
                setFormData({ ...formData, imageId: value })
              }
              disabled={isLoading}
            >
              <SelectTrigger className="w-full bg-gray-900 border-gray-700 text-gray-100">
                <SelectValue placeholder="Select an image" />
              </SelectTrigger>
              <SelectContent className="bg-gray-800 border-gray-700">
                {readyImages.map((image) => (
                  <SelectItem
                    key={image.id}
                    value={image.id}
                    className="text-gray-100 focus:bg-gray-700 focus:text-gray-100"
                  >
                    <div className="flex items-center gap-2">
                      <HardDrive className="h-4 w-4 text-gray-400" />
                      <span>{image.name}</span>
                      <span className="text-gray-500 text-xs">
                        ({image.sizeFormatted})
                      </span>
                    </div>
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        </div>
      );
    }

    return (
      <div className="space-y-2">
        <Label htmlFor="template" className="text-gray-200">
          OS Template (Legacy)
        </Label>
        <Input
          id="template"
          placeholder="ubuntu-22.04"
          value={formData.templateName}
          onChange={(e) =>
            setFormData({ ...formData, templateName: e.target.value })
          }
          className="bg-gray-900 border-gray-700 text-gray-100"
          disabled={isLoading}
        />
        <p className="text-xs text-yellow-500">
          Templates are deprecated. Consider uploading an image instead.
        </p>
      </div>
    );
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-gray-800 border-gray-700 text-gray-100">
        <DialogHeader>
          <DialogTitle>Create Virtual Machine</DialogTitle>
          <DialogDescription className="text-gray-400">
            Configure your new virtual machine
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="name" className="text-gray-200">
                VM Name
              </Label>
              <Input
                id="name"
                placeholder="my-vm"
                value={formData.name}
                onChange={(e) =>
                  setFormData({ ...formData, name: e.target.value })
                }
                className="bg-gray-900 border-gray-700 text-gray-100"
                disabled={isLoading}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="description" className="text-gray-200">
                Description
              </Label>
              <Input
                id="description"
                placeholder="Production web server"
                value={formData.description}
                onChange={(e) =>
                  setFormData({ ...formData, description: e.target.value })
                }
                className="bg-gray-900 border-gray-700 text-gray-100"
                disabled={isLoading}
              />
            </div>

            {/* Source Type Selector */}
            <div className="space-y-2">
              <Label className="text-gray-200">Disk Source</Label>
              <div className="flex gap-2">
                <Button
                  type="button"
                  variant={sourceType === "image" ? "default" : "outline"}
                  size="sm"
                  onClick={() => setSourceType("image")}
                  className={
                    sourceType === "image"
                      ? "bg-blue-600 hover:bg-blue-700"
                      : "border-gray-600 text-gray-300 hover:bg-gray-700"
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
                      ? "bg-blue-600 hover:bg-blue-700"
                      : "border-gray-600 text-gray-300 hover:bg-gray-700"
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
                <Label htmlFor="cpu" className="text-gray-200">
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
                  className="bg-gray-900 border-gray-700 text-gray-100"
                  disabled={isLoading}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="memory" className="text-gray-200">
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
                  className="bg-gray-900 border-gray-700 text-gray-100"
                  disabled={isLoading}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="disk" className="text-gray-200">
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
                  className="bg-gray-900 border-gray-700 text-gray-100"
                  disabled={isLoading}
                />
              </div>
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
                "Create VM"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
