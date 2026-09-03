"use client";

import { DialogSubmitFooter } from "@/components/ui/dialog-submit-footer";

import { useState } from "react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { volumesApi } from "@/lib/api/volumes";
import { useAcceptedMutation } from "@/lib/hooks/use-accepted-mutation";
import { toast } from "sonner";

import type { Volume } from "@/types/api";

interface CloneVolumeDialogProps {
  volume: Volume;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSuccess?: () => void;
}

export function CloneVolumeDialog({
  volume,
  open,
  onOpenChange,
  onSuccess,
}: CloneVolumeDialogProps) {
  const { isLoading, run } = useAcceptedMutation();
  const [name, setName] = useState(`${volume.name}-clone`);
  const [description, setDescription] = useState("");

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const trimmedName = name.trim();
    if (!trimmedName) {
      toast.error("Please enter a name for the clone");
      return;
    }

    // The accepted mutation is a `create` on the *clone*, not an operation
    // on the source: cloning is a create strategy on the new volume's
    // desired entry (backend STR-148), so the source is only ever read.
    const payload = {
      name: trimmedName,
      description: description.trim() || undefined,
    };
    await run({
      intentKey: JSON.stringify(["POST", `/api/volumes/${volume.id}/clone`, payload]),
      request: (idempotencyKey) =>
        volumesApi.clone(volume.id!, payload, idempotencyKey),
      watch: {
        kind: "create",
        resourceKind: "volume",
        resourceName: trimmedName,
      },
      errorMessage: "Failed to clone volume",
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
          <DialogTitle>Clone {volume.name}</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Create a full copy of this volume ({volume.sizeFormatted}). Cloning
            large volumes can take several minutes.
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="cloneName" className="text-foreground">
                Name
              </Label>
              <Input
                id="cloneName"
                value={name}
                onChange={(e) => setName(e.target.value)}
                className="bg-background border-border text-foreground"
                disabled={isLoading}
                autoFocus
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="cloneDescription" className="text-foreground">
                Description
              </Label>
              <Input
                id="cloneDescription"
                placeholder={`Clone of ${volume.name}`}
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                className="bg-background border-border text-foreground"
                disabled={isLoading}
              />
            </div>
          </div>
          <DialogSubmitFooter
            submitLabel="Clone"
            pendingLabel="Cloning..."
            isPending={isLoading}
            onCancel={() => onOpenChange(false)}
          />
        </form>
      </DialogContent>
    </Dialog>
  );
}
