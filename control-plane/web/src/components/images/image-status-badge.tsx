"use client";

import {
  StatusBadge,
  type StatusBadgeConfig,
} from "@/components/ui/status-badge";
import type { ImageStatus } from "@/types/api";

interface ImageStatusBadgeProps {
  status: ImageStatus;
  downloadProgress?: number;
}

const statusConfig: Record<ImageStatus, StatusBadgeConfig> = {
  ready: {
    label: "Ready",
    className: "bg-green-500/20 text-green-600 border-green-500/30 border",
  },
  uploading: {
    label: "Uploading",
    className: "bg-blue-500/20 text-blue-600 border-blue-500/30 border",
  },
  downloading: {
    label: "Downloading",
    className: "bg-blue-500/20 text-blue-600 border-blue-500/30 border",
  },
  validating: {
    label: "Validating",
    className: "bg-yellow-500/20 text-yellow-700 border-yellow-500/30 border",
  },
  pending: {
    label: "Pending",
    className:
      "bg-gray-500/20 text-muted-foreground border-gray-500/30 border",
  },
  error: {
    label: "Error",
    className: "bg-red-500/20 text-red-600 border-red-500/30 border",
  },
};

export function ImageStatusBadge({
  status,
  downloadProgress,
}: ImageStatusBadgeProps) {
  const config =
    downloadProgress !== undefined
      ? {
          ...statusConfig,
          uploading: {
            ...statusConfig.uploading,
            label: `Uploading ${downloadProgress}%`,
          },
          downloading: {
            ...statusConfig.downloading,
            label: `Downloading ${downloadProgress}%`,
          },
        }
      : statusConfig;

  return <StatusBadge status={status} config={config} />;
}
