"use client";

import { useState } from "react";
import {
  Camera,
  Copy,
  Expand,
  Link2,
  Loader2,
  MoreHorizontal,
  Trash2,
  Unlink,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { volumesApi } from "@/lib/api/volumes";
import { useAcceptedMutation } from "@/lib/hooks/use-accepted-mutation";
import { volumeBytesAtRest } from "@/lib/volume-guards";
import { usePendingMutation } from "@/lib/stores/mutations-store";
import { usePermissions } from "@/lib/hooks/use-permissions";
import type { Volume } from "@/types/api";
import { AttachVolumeDialog } from "./attach-volume-dialog";
import { ResizeVolumeDialog } from "./resize-volume-dialog";
import { CreateSnapshotDialog } from "./create-snapshot-dialog";
import { CloneVolumeDialog } from "./clone-volume-dialog";

interface VolumeActionsProps {
  volume: Volume;
  onActionComplete?: () => void;
  allowedActions?: Partial<Record<VolumeActionPermission, boolean>>;
}

type VolumeDialog = "attach" | "resize" | "snapshot" | "clone" | "delete";
type VolumeActionPermission = VolumeDialog | "detach";

export function VolumeActions({ volume, onActionComplete, allowedActions }: VolumeActionsProps) {
  const [openDialog, setOpenDialog] = useState<VolumeDialog | null>(null);
  const { isLoading, run } = useAcceptedMutation();
  const pendingMutation = usePendingMutation(volume.id);
  const { permissions: queriedPermissions } = usePermissions(
    volume.id && !allowedActions
      ? [
          { key: "attach", action: "volume:attach", node: { type: "volume", id: volume.id } },
          { key: "detach", action: "volume:detach", node: { type: "volume", id: volume.id } },
          { key: "resize", action: "volume:update", node: { type: "volume", id: volume.id } },
          { key: "snapshot", action: "volume:snapshot", node: { type: "volume", id: volume.id } },
          { key: "clone", action: "volume:clone", node: { type: "volume", id: volume.id } },
          { key: "delete", action: "volume:delete", node: { type: "volume", id: volume.id } },
        ]
      : []
  );
  const permissions = allowedActions ?? queriedPermissions;

  // Detach and delete are accepted, not performed (backend STR-148): the toast
  // comes from MutationWatcher once the volume's `conditions` say the agent
  // converged, not from the 202 that only says the request was recorded.
  const handleDetach = () =>
    run({
      request: () => volumesApi.detach(volume.id!),
      watch: {
        kind: "detach",
        resourceKind: "volume",
        resourceId: volume.id!,
        resourceName: volume.name,
      },
      errorMessage: "Failed to detach volume",
      onSuccess: () => onActionComplete?.(),
    });

  const handleDelete = () =>
    run({
      request: () => volumesApi.delete(volume.id!),
      watch: {
        kind: "delete",
        resourceKind: "volume",
        resourceId: volume.id!,
        resourceName: volume.name,
      },
      errorMessage: "Failed to delete volume",
      onSuccess: () => {
        setOpenDialog(null);
        onActionComplete?.();
      },
    });

  // Mirror the backend's guards so we don't offer a mutation it would answer
  // 409 to. They are about *attachment* now, not about an observed status
  // (backend STR-148) — a volume mid-convergence is still attachable, because
  // the agent sequences the two steps itself.
  const attached = !!volume.vmId;
  const canAttach = !attached;
  const canDetach = attached;
  const canResize = !attached;
  // Snapshot and clone both read the volume's bytes, so they additionally need
  // it settled: copying a volume mid-create yields a torn image. `bytesAtRest`
  // rather than `conditions.converged` — see the helper for why the two parted
  // company (backend STR-191).
  const atRest = volumeBytesAtRest(volume);
  const canSnapshot = !attached && atRest;
  const canClone = !attached && atRest;
  const canDelete = !attached;

  const closeDialog = () => setOpenDialog(null);
  const handleDialogSuccess = () => {
    onActionComplete?.();
  };

  return (
    <div className="flex items-center justify-end">
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button
            size="sm"
            variant="ghost"
            className="text-muted-foreground hover:text-foreground"
            disabled={isLoading || !!pendingMutation}
            aria-label={`Actions for ${volume.name}`}
          >
            {isLoading || pendingMutation ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              <MoreHorizontal className="h-4 w-4" />
            )}
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent className="bg-card border-border">
          <DropdownMenuItem
            onClick={() => setOpenDialog("attach")}
            className="text-foreground hover:bg-accent cursor-pointer"
            disabled={!canAttach || !permissions.attach}
          >
            <Link2 className="h-4 w-4 mr-2 text-blue-600" />
            Attach to VM
          </DropdownMenuItem>
          <DropdownMenuItem
            onClick={handleDetach}
            className="text-foreground hover:bg-accent cursor-pointer"
            disabled={!canDetach || !permissions.detach}
          >
            <Unlink className="h-4 w-4 mr-2 text-yellow-700" />
            Detach
          </DropdownMenuItem>
          <DropdownMenuItem
            onClick={() => setOpenDialog("resize")}
            className="text-foreground hover:bg-accent cursor-pointer"
            disabled={!canResize || !permissions.resize}
          >
            <Expand className="h-4 w-4 mr-2 text-blue-600" />
            Resize
          </DropdownMenuItem>
          <DropdownMenuItem
            onClick={() => setOpenDialog("snapshot")}
            className="text-foreground hover:bg-accent cursor-pointer"
            disabled={!canSnapshot || !permissions.snapshot}
          >
            <Camera className="h-4 w-4 mr-2 text-purple-600" />
            Snapshot
          </DropdownMenuItem>
          <DropdownMenuItem
            onClick={() => setOpenDialog("clone")}
            className="text-foreground hover:bg-accent cursor-pointer"
            disabled={!canClone || !permissions.clone}
          >
            <Copy className="h-4 w-4 mr-2 text-purple-600" />
            Clone
          </DropdownMenuItem>
          <DropdownMenuSeparator className="bg-muted" />
          <DropdownMenuItem
            onClick={() => setOpenDialog("delete")}
            className="text-red-600 hover:bg-red-500/10 cursor-pointer"
            disabled={!canDelete || !permissions.delete}
          >
            <Trash2 className="h-4 w-4 mr-2" />
            Delete
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>

      <AttachVolumeDialog
        volume={volume}
        open={openDialog === "attach"}
        onOpenChange={(open) => !open && closeDialog()}
        onSuccess={handleDialogSuccess}
      />
      <ResizeVolumeDialog
        key={`resize-${volume.size}`}
        volume={volume}
        open={openDialog === "resize"}
        onOpenChange={(open) => !open && closeDialog()}
        onSuccess={handleDialogSuccess}
      />
      <CreateSnapshotDialog
        volume={volume}
        open={openDialog === "snapshot"}
        onOpenChange={(open) => !open && closeDialog()}
        onSuccess={handleDialogSuccess}
      />
      <CloneVolumeDialog
        volume={volume}
        open={openDialog === "clone"}
        onOpenChange={(open) => !open && closeDialog()}
        onSuccess={handleDialogSuccess}
      />

      {/* Delete confirmation dialog */}
      <Dialog
        open={openDialog === "delete"}
        onOpenChange={(open) => !open && closeDialog()}
      >
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Delete {volume.name}?</DialogTitle>
            <DialogDescription className="text-muted-foreground">
              This will permanently delete the volume and all of its
              snapshots. This action cannot be undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={closeDialog}
              className="border-input text-foreground/80 hover:bg-accent"
              disabled={isLoading}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={handleDelete}
              disabled={isLoading}
            >
              {isLoading ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Trash2 className="h-4 w-4" />
              )}
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
