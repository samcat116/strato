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
import { useAcceptedMutation } from "@/lib/hooks/use-accepted-mutation";
import { toast } from "sonner";

import type { Volume } from "@/types/api";

interface ResizeVolumeDialogProps {
  volume: Volume;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSuccess?: () => void;
}

// The API request field is spelled `sizeGB`, but the unit has always been
// binary — one of these is a gibibyte.
const GB = 1024 * 1024 * 1024;

export function ResizeVolumeDialog({
  volume,
  open,
  onOpenChange,
  onSuccess,
}: ResizeVolumeDialogProps) {
  // The floor is the size already *requested*, because that is what the
  // endpoint compares against — a grow to less than an outstanding one is
  // refused with a 400 even when the image on disk is smaller still.
  const currentSizeGB = Math.ceil(volume.size / GB);
  // What is actually on disk, when the owning agent has reported it. A grow the
  // agent has refused leaves the two apart for as long as the refusal holds
  // (backend STR-199), and telling the operator the requested number is
  // "current" is the conflation that made a refused grow look applied.
  const growOutstanding =
    volume.observedSize != null && volume.observedSize < volume.size;
  const sizeSummary = growOutstanding
    ? `On disk: ${volume.observedSizeFormatted} (${volume.sizeFormatted} requested, not applied yet).`
    : `Current size: ${volume.observedSizeFormatted ?? volume.sizeFormatted}.`;
  const { isLoading, run } = useAcceptedMutation();
  const [sizeGB, setSizeGB] = useState(String(currentSizeGB));

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const newSize = parseInt(sizeGB);
    if (!newSize || newSize <= currentSizeGB) {
      toast.error(
        `New size must be larger than the size already requested (${volume.sizeFormatted})`
      );
      return;
    }

    await run({
      request: () => volumesApi.resize(volume.id!, { sizeGB: newSize }),
      watch: {
        kind: "resize",
        resourceKind: "volume",
        resourceId: volume.id!,
        resourceName: volume.name,
      },
      errorMessage: "Failed to resize volume",
      onSuccess: () => {
        onOpenChange(false);
        onSuccess?.();
      },
    });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>Resize {volume.name}</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            {sizeSummary} Volumes can only grow. One attached to a running VM
            cannot be grown yet — stop the VM or detach the volume, and the
            resize completes on its own.
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="resizeSize" className="text-foreground">
                New Size (GiB)
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
