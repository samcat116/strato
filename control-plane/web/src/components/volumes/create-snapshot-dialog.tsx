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
import { volumeBytesAtRest } from "@/lib/volume-guards";
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
  const { isLoading, run } = useAcceptedMutation();
  const [volumeId, setVolumeId] = useState(volume?.id ?? "");
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");

  // Detached volumes only: a snapshot of a volume a guest is still writing
  // would not be point-in-time (issue #747), so the backend refuses it. It
  // additionally requires the volume's bytes settled (backend STR-148) —
  // snapshotting one mid-create would copy a half-written file.
  const candidateVolumes = (volumes ?? []).filter(
    (v) => v.id && !v.vmId && volumeBytesAtRest(v)
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

    const payload = {
      name: trimmedName,
      description: description.trim() || undefined,
    };
    await run({
      intentKey: JSON.stringify(["POST", `/api/volumes/${targetId}/snapshot`, payload]),
      request: (idempotencyKey) =>
        volumesApi.snapshot(targetId, payload, idempotencyKey),
      watch: {
        snapshot: true,
        kind: "create",
        resourceKind: "volume_snapshot",
        resourceName: trimmedName,
      },
      errorMessage: "Failed to create snapshot",
      successMessage: `Snapshot "${trimmedName}" is being created`,
      onSuccess: () => {
        onOpenChange(false);
        onSuccess?.();
        setName("");
        setDescription("");
        if (!volume) setVolumeId("");
      },
    });
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
                    No volumes can be snapshotted right now. Detach a volume
                    from its VM to snapshot it.
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
          <DialogSubmitFooter
            submitLabel="Create Snapshot"
            pendingLabel="Creating..."
            isPending={isLoading}
            disabled={(!volume && candidateVolumes.length === 0)}
            onCancel={() => onOpenChange(false)}
          />
        </form>
      </DialogContent>
    </Dialog>
  );
}
