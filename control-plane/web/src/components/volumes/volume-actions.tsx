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
import { volumeBytesAtRest } from "@/lib/volume-guards";
import { toast } from "sonner";
import {
  acceptedMutation,
  usePendingMutation,
  useMutationsStore,
} from "@/lib/stores/mutations-store";
import type { Volume } from "@/types/api";
import { AttachVolumeDialog } from "./attach-volume-dialog";
import { ResizeVolumeDialog } from "./resize-volume-dialog";
import { CreateSnapshotDialog } from "./create-snapshot-dialog";
import { CloneVolumeDialog } from "./clone-volume-dialog";

interface VolumeActionsProps {
  volume: Volume;
  onActionComplete?: () => void;
}

type VolumeDialog = "attach" | "resize" | "snapshot" | "clone" | "delete";

export function VolumeActions({ volume, onActionComplete }: VolumeActionsProps) {
  const [isLoading, setIsLoading] = useState(false);
  const [openDialog, setOpenDialog] = useState<VolumeDialog | null>(null);
  const watch = useMutationsStore((state) => state.watch);
  const pendingMutation = usePendingMutation(volume.id);

  // Detach and delete are accepted, not performed (backend STR-148): the toast
  // comes from MutationWatcher once the volume's `conditions` say the agent
  // converged, not from the 202 that only says the request was recorded.
  const handleDetach = async () => {
    setIsLoading(true);
    try {
      watch(
        acceptedMutation(await volumesApi.detach(volume.id!), {
          kind: "detach",
          resourceKind: "volume",
          resourceId: volume.id!,
          resourceName: volume.name,
        })
      );
      onActionComplete?.();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to detach volume"
      );
    } finally {
      setIsLoading(false);
    }
  };

  const handleDelete = async () => {
    setIsLoading(true);
    try {
      watch(
        acceptedMutation(await volumesApi.delete(volume.id!), {
          kind: "delete",
          resourceKind: "volume",
          resourceId: volume.id!,
          resourceName: volume.name,
        })
      );
      setOpenDialog(null);
      onActionComplete?.();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to delete volume"
      );
    } finally {
      setIsLoading(false);
    }
  };

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
            disabled={!canAttach}
          >
            <Link2 className="h-4 w-4 mr-2 text-blue-600" />
            Attach to VM
          </DropdownMenuItem>
          <DropdownMenuItem
            onClick={handleDetach}
            className="text-foreground hover:bg-accent cursor-pointer"
            disabled={!canDetach}
          >
            <Unlink className="h-4 w-4 mr-2 text-yellow-700" />
            Detach
          </DropdownMenuItem>
          <DropdownMenuItem
            onClick={() => setOpenDialog("resize")}
            className="text-foreground hover:bg-accent cursor-pointer"
            disabled={!canResize}
          >
            <Expand className="h-4 w-4 mr-2 text-blue-600" />
            Resize
          </DropdownMenuItem>
          <DropdownMenuItem
            onClick={() => setOpenDialog("snapshot")}
            className="text-foreground hover:bg-accent cursor-pointer"
            disabled={!canSnapshot}
          >
            <Camera className="h-4 w-4 mr-2 text-purple-600" />
            Snapshot
          </DropdownMenuItem>
          <DropdownMenuItem
            onClick={() => setOpenDialog("clone")}
            className="text-foreground hover:bg-accent cursor-pointer"
            disabled={!canClone}
          >
            <Copy className="h-4 w-4 mr-2 text-purple-600" />
            Clone
          </DropdownMenuItem>
          <DropdownMenuSeparator className="bg-muted" />
          <DropdownMenuItem
            onClick={() => setOpenDialog("delete")}
            className="text-red-600 hover:bg-red-500/10 cursor-pointer"
            disabled={!canDelete}
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
