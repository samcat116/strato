"use client";

import { useState } from "react";
import {
  MoreHorizontal,
  Download,
  Pencil,
  Trash2,
  Loader2,
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
import { EditImageDialog } from "./edit-image-dialog";
import { useDeleteImage } from "@/lib/hooks/use-images";
import { imagesApi } from "@/lib/api/images";
import { toast } from "sonner";
import type { Image } from "@/types/api";

interface ImageActionsProps {
  image: Image;
  projectId: string;
  onActionComplete?: () => void;
}

export function ImageActions({
  image,
  projectId,
  onActionComplete,
}: ImageActionsProps) {
  const [editOpen, setEditOpen] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const deleteImage = useDeleteImage(projectId);

  const handleDelete = async () => {
    if (!image.id) {
      console.error("Cannot delete image without ID");
      return;
    }

    try {
      await deleteImage.mutateAsync(image.id);
      setShowDeleteConfirm(false);
      toast.success(`Deleted ${image.name}`);
      onActionComplete?.();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to delete image"
      );
    }
  };

  const handleDownload = () => {
    if (!image.id) {
      console.error("Cannot download image without ID");
      return;
    }
    const downloadURL = imagesApi.getDownloadURL(projectId, image.id);
    window.open(downloadURL, "_blank");
  };

  const canDownload = image.status === "ready";

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button
            variant="ghost"
            className="h-8 w-8 p-0 text-muted-foreground hover:text-foreground"
          >
            <MoreHorizontal className="h-4 w-4" />
            <span className="sr-only">Open menu</span>
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent
          align="end"
          className="bg-card border-border text-foreground"
        >
          <DropdownMenuItem
            onClick={handleDownload}
            disabled={!canDownload}
            className="hover:bg-accent cursor-pointer"
          >
            <Download className="mr-2 h-4 w-4" />
            Download
          </DropdownMenuItem>
          <DropdownMenuItem
            onClick={() => setEditOpen(true)}
            className="hover:bg-accent cursor-pointer"
          >
            <Pencil className="mr-2 h-4 w-4" />
            Edit
          </DropdownMenuItem>
          <DropdownMenuSeparator className="bg-muted" />
          <DropdownMenuItem
            onClick={() => setShowDeleteConfirm(true)}
            disabled={deleteImage.isPending}
            className="hover:bg-accent cursor-pointer text-red-600"
          >
            <Trash2 className="mr-2 h-4 w-4" />
            Delete
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>

      {editOpen && (
        <EditImageDialog
          image={image}
          projectId={projectId}
          open={editOpen}
          onOpenChange={setEditOpen}
        />
      )}

      {/* Delete confirmation dialog */}
      <Dialog open={showDeleteConfirm} onOpenChange={setShowDeleteConfirm}>
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Delete {image.name}?</DialogTitle>
            <DialogDescription className="text-muted-foreground">
              This will permanently delete the image. VMs already created from
              it are not affected. This action cannot be undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              className="border-input"
              onClick={() => setShowDeleteConfirm(false)}
              disabled={deleteImage.isPending}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={handleDelete}
              disabled={deleteImage.isPending}
            >
              {deleteImage.isPending ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Trash2 className="h-4 w-4" />
              )}
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
