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
import { volumesApi } from "@/lib/api/volumes";
import { toast } from "sonner";
import type { Volume } from "@/types/api";

interface ResizeVolumeDialogProps {
  volume: Volume;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSuccess?: () => void;
}

const GB = 1024 * 1024 * 1024;

export function ResizeVolumeDialog({
  volume,
  open,
  onOpenChange,
  onSuccess,
}: ResizeVolumeDialogProps) {
  const currentSizeGB = Math.ceil(volume.size / GB);
  const [isLoading, setIsLoading] = useState(false);
  const [sizeGB, setSizeGB] = useState(String(currentSizeGB));

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const newSize = parseInt(sizeGB);
    if (!newSize || newSize <= currentSizeGB) {
      toast.error(
        `New size must be larger than the current size (${volume.sizeFormatted})`
      );
      return;
    }

    setIsLoading(true);
    try {
      await volumesApi.resize(volume.id!, { sizeGB: newSize });
      toast.success(`Resizing ${volume.name} to ${newSize} GB`);
      onOpenChange(false);
      onSuccess?.();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to resize volume"
      );
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>Resize {volume.name}</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Current size: {volume.sizeFormatted}. Volumes can only grow, and
            must be detached to resize.
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="resizeSize" className="text-foreground">
                New Size (GB)
              </Label>
              <Input
                id="resizeSize"
                type="number"
                min={currentSizeGB + 1}
                value={sizeGB}
                onChange={(e) => setSizeGB(e.target.value)}
                className="bg-background border-border text-foreground"
                disabled={isLoading}
                autoFocus
              />
            </div>
          </div>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => onOpenChange(false)}
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
                  Resizing...
                </>
              ) : (
                "Resize"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
