"use client";

import { useState } from "react";
import { MoreHorizontal, Download, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useDeleteImage } from "@/lib/hooks/use-images";
import { imagesApi } from "@/lib/api/images";
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
  const [isDeleting, setIsDeleting] = useState(false);
  const deleteImage = useDeleteImage(projectId);

  const handleDelete = async () => {
    if (!image.id) {
      console.error("Cannot delete image without ID");
      return;
    }

    if (!confirm(`Are you sure you want to delete "${image.name}"?`)) {
      return;
    }

    setIsDeleting(true);
    try {
      await deleteImage.mutateAsync(image.id);
      onActionComplete?.();
    } catch (error) {
      console.error("Failed to delete image:", error);
      alert("Failed to delete image. Please try again.");
    } finally {
      setIsDeleting(false);
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
  const canDelete = !isDeleting;

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button
          variant="ghost"
          className="h-8 w-8 p-0 text-gray-400 hover:text-gray-100"
        >
          <MoreHorizontal className="h-4 w-4" />
          <span className="sr-only">Open menu</span>
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent
        align="end"
        className="bg-gray-800 border-gray-700 text-gray-100"
      >
        <DropdownMenuItem
          onClick={handleDownload}
          disabled={!canDownload}
          className="hover:bg-gray-700 cursor-pointer"
        >
          <Download className="mr-2 h-4 w-4" />
          Download
        </DropdownMenuItem>
        <DropdownMenuItem
          onClick={handleDelete}
          disabled={!canDelete}
          className="hover:bg-gray-700 cursor-pointer text-red-400"
        >
          <Trash2 className="mr-2 h-4 w-4" />
          {isDeleting ? "Deleting..." : "Delete"}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
