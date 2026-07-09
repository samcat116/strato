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
import { toast } from "sonner";
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

  const handleDetach = async () => {
    setIsLoading(true);
    try {
      await volumesApi.detach(volume.id!);
      toast.success(`Detached ${volume.name}`);
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
      await volumesApi.delete(volume.id!);
      setOpenDialog(null);
      toast.success(`Deleted ${volume.name}`);
      onActionComplete?.();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to delete volume"
      );
    } finally {
      setIsLoading(false);
    }
  };

  // Mirror the backend's status gates so we don't offer operations
  // that would be rejected with a 409.
  const canAttach = volume.status === "available";
  const canDetach = volume.status === "attached";
  const canResize = volume.status === "available";
  const canSnapshot =
    volume.status === "available" || volume.status === "attached";
  const canClone = volume.status === "available";
  const canDelete =
    volume.status === "available" ||
    volume.status === "error" ||
    volume.status === "deleting";

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
            disabled={isLoading}
          >
            {isLoading ? (
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
