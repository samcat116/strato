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

interface CreateSnapshotDialogProps {
  /** Fixed target volume; when omitted, `volumes` is shown as a selector. */
  volume?: Volume;
  /** Candidate volumes for the selector variant (snapshots page). */
  volumes?: Volume[];
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSuccess?: () => void;
}

const selectClassName =
  "w-full h-9 px-3 py-2 bg-background border border-border text-foreground rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed";

export function CreateSnapshotDialog({
  volume,
  volumes,
  open,
  onOpenChange,
  onSuccess,
}: CreateSnapshotDialogProps) {
  const [isLoading, setIsLoading] = useState(false);
  const [volumeId, setVolumeId] = useState(volume?.id ?? "");
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");

  // Only available/attached volumes can be snapshotted
  const candidateVolumes = (volumes ?? []).filter(
    (v) => v.id && (v.status === "available" || v.status === "attached")
  );

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const targetId = volume?.id ?? volumeId;
    if (!targetId) {
      toast.error("Please select a volume");
      return;
    }

    const trimmedName = name.trim();
    if (!trimmedName) {
      toast.error("Please enter a snapshot name");
      return;
    }

    setIsLoading(true);
    try {
      await volumesApi.snapshot(targetId, {
        name: trimmedName,
        description: description.trim() || undefined,
      });
      toast.success(`Snapshot "${trimmedName}" is being created`);
      onOpenChange(false);
      onSuccess?.();
      setName("");
      setDescription("");
      if (!volume) setVolumeId("");
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to create snapshot"
      );
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>
            {volume ? `Snapshot ${volume.name}` : "Create Snapshot"}
          </DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Capture a point-in-time copy of the volume.
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            {!volume && (
              <div className="space-y-2">
                <Label htmlFor="snapshotVolume" className="text-foreground">
                  Volume
                </Label>
                {candidateVolumes.length === 0 ? (
                  <div className="text-sm text-muted-foreground py-2">
                    No volumes can be snapshotted right now. Volumes must be
                    available or attached.
                  </div>
                ) : (
                  <select
                    id="snapshotVolume"
                    value={volumeId}
                    onChange={(e) => setVolumeId(e.target.value)}
                    disabled={isLoading}
                    className={selectClassName}
                  >
                    <option value="" disabled>
                      Select a volume
                    </option>
                    {candidateVolumes.map((v) => (
                      <option key={v.id} value={v.id!}>
                        {v.name} ({v.sizeFormatted})
                      </option>
                    ))}
                  </select>
                )}
              </div>
            )}
            <div className="space-y-2">
              <Label htmlFor="snapshotName" className="text-foreground">
                Name
              </Label>
              <Input
                id="snapshotName"
                placeholder="before-upgrade"
                value={name}
                onChange={(e) => setName(e.target.value)}
                className="bg-background border-border text-foreground"
                disabled={isLoading}
                autoFocus
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="snapshotDescription" className="text-foreground">
                Description
              </Label>
              <Input
                id="snapshotDescription"
                placeholder="Snapshot before OS upgrade"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                className="bg-background border-border text-foreground"
                disabled={isLoading}
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
              disabled={isLoading || (!volume && candidateVolumes.length === 0)}
            >
              {isLoading ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Creating...
                </>
              ) : (
                "Create Snapshot"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
