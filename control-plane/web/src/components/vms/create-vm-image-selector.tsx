"use client";

import Link from "next/link";
import { Loader2 } from "lucide-react";
import { Label } from "@/components/ui/label";
import type { Image } from "@/types/api";

interface VMImageSelectorProps {
  projectId?: string;
  imagesLoading: boolean;
  readyImages: Image[];
  imageId: string;
  isLoading: boolean;
  onSelect: (imageId: string) => void;
}

export function VMImageSelector({
  projectId,
  imagesLoading,
  readyImages,
  imageId,
  isLoading,
  onSelect,
}: VMImageSelectorProps) {
  return (
    <div className="space-y-2">
      <Label htmlFor="image" className="text-foreground">
        Disk Image
      </Label>
      {!projectId ? (
        <div className="text-sm text-muted-foreground py-2">
          No project available. Create a project first to upload images.
        </div>
      ) : imagesLoading ? (
        <div className="flex items-center gap-2 text-muted-foreground text-sm">
          <Loader2 className="h-4 w-4 animate-spin" />
          Loading images...
        </div>
      ) : readyImages.length === 0 ? (
        <div className="text-sm text-muted-foreground py-2">
          No images available.{" "}
          <Link href="/images" className="text-blue-600 hover:underline">
            Upload an image
          </Link>{" "}
          first.
        </div>
      ) : (
        <select
          value={imageId}
          onChange={(event) => onSelect(event.target.value)}
          disabled={isLoading}
          className="w-full h-9 px-3 py-2 bg-background border border-border text-foreground rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed"
        >
          <option value="" disabled>
            Select an image
          </option>
          {readyImages.map((image) => (
            <option key={image.id} value={image.id!}>
              {image.name}
              {image.sizeFormatted ? ` (${image.sizeFormatted})` : ""}
            </option>
          ))}
        </select>
      )}
    </div>
  );
}
