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
          <Skeleton key={i} className="h-12 w-full bg-gray-700" />
        ))}
      </div>
    );
  }

  if (images.length === 0) {
    return (
      <div className="text-center py-8 text-gray-400">
        No images found. Upload an image or fetch from URL to get started.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-gray-900">
        <TableRow className="border-gray-700 hover:bg-gray-900">
          <TableHead className="text-gray-400 font-medium">Name</TableHead>
          <TableHead className="text-gray-400 font-medium">Status</TableHead>
          <TableHead className="text-gray-400 font-medium">Format</TableHead>
          <TableHead className="text-gray-400 font-medium">Size</TableHead>
          <TableHead className="text-gray-400 font-medium">
            Created
          </TableHead>
          <TableHead className="text-gray-400 font-medium text-right">
            Actions
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-gray-700">
        {images.map((image) => (
          <TableRow
            key={image.id}
            className="border-gray-700 hover:bg-gray-800/50"
          >
            <TableCell>
              <div className="font-medium text-gray-100">{image.name}</div>
              {image.description && (
                <p className="text-sm text-gray-500 truncate max-w-xs">
                  {image.description}
                </p>
              )}
              <p className="text-xs text-gray-600 truncate max-w-xs">
                {image.filename}
              </p>
            </TableCell>
            <TableCell>
              <ImageStatusBadge
                status={image.status}
                downloadProgress={image.downloadProgress}
              />
              {image.errorMessage && (
                <p className="text-xs text-red-400 mt-1 truncate max-w-xs">
                  {image.errorMessage}
                </p>
              )}
            </TableCell>
            <TableCell className="text-gray-300 uppercase">
              {image.format}
            </TableCell>
            <TableCell className="text-gray-300">
              {image.sizeFormatted || "—"}
            </TableCell>
            <TableCell className="text-gray-300">
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
