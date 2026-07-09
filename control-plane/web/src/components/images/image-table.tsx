"use client";

import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Skeleton } from "@/components/ui/skeleton";
import { ImageStatusBadge } from "./image-status-badge";
import { ImageActions } from "./image-actions";
import type { Image } from "@/types/api";

interface ImageTableProps {
  images: Image[];
  projectId: string;
  isLoading?: boolean;
  onRefresh?: () => void;
}

export function ImageTable({
  images,
  projectId,
  isLoading,
  onRefresh,
}: ImageTableProps) {
  if (isLoading) {
    return (
      <div className="space-y-2">
        {[...Array(3)].map((_, i) => (
          <Skeleton key={i} className="h-12 w-full bg-muted" />
        ))}
      </div>
    );
  }

  if (images.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        No images found. Upload an image or fetch from URL to get started.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">Name</TableHead>
          <TableHead className="text-muted-foreground font-medium">Status</TableHead>
          <TableHead className="text-muted-foreground font-medium">Format</TableHead>
          <TableHead className="text-muted-foreground font-medium">Arch</TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Compatible
          </TableHead>
          <TableHead className="text-muted-foreground font-medium">Size</TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Created
          </TableHead>
          <TableHead className="text-muted-foreground font-medium text-right">
            Actions
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {images.map((image) => (
          <TableRow
            key={image.id}
            className="border-border hover:bg-accent/60"
          >
            <TableCell>
              <div className="font-medium text-foreground">{image.name}</div>
              {image.description && (
                <p className="text-sm text-muted-foreground truncate max-w-xs">
                  {image.description}
                </p>
              )}
              <p className="text-xs text-muted-foreground truncate max-w-xs">
                {image.filename}
              </p>
            </TableCell>
            <TableCell>
              <ImageStatusBadge
                status={image.status}
                downloadProgress={image.downloadProgress}
              />
              {image.errorMessage && (
                <p className="text-xs text-red-600 mt-1 truncate max-w-xs">
                  {image.errorMessage}
                </p>
              )}
            </TableCell>
            <TableCell className="text-foreground/80 uppercase">
              {image.format}
            </TableCell>
            <TableCell className="text-foreground/80">
              {image.architecture}
            </TableCell>
            <TableCell className="text-foreground/80">
              {image.compatibleHypervisors &&
              image.compatibleHypervisors.length > 0 ? (
                <div className="flex flex-wrap gap-1">
                  {image.compatibleHypervisors.map((h) => (
                    <span
                      key={h}
                      className="rounded bg-muted px-1.5 py-0.5 text-xs text-foreground"
                    >
                      {h}
                    </span>
                  ))}
                </div>
              ) : (
                <span className="text-muted-foreground">—</span>
              )}
            </TableCell>
            <TableCell className="text-foreground/80">
              {image.sizeFormatted || "—"}
            </TableCell>
            <TableCell className="text-foreground/80">
              {image.createdAt
                ? new Date(image.createdAt).toLocaleDateString()
                : "—"}
            </TableCell>
            <TableCell className="text-right">
              <ImageActions
                image={image}
                projectId={projectId}
                onActionComplete={onRefresh}
              />
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
