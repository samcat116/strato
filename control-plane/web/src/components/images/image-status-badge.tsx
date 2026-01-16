"use client";

import { Badge } from "@/components/ui/badge";
import type { ImageStatus } from "@/types/api";

interface ImageStatusBadgeProps {
  status: ImageStatus;
  downloadProgress?: number;
}

export function ImageStatusBadge({
  status,
  downloadProgress,
}: ImageStatusBadgeProps) {
  const getStatusColor = () => {
    switch (status) {
      case "ready":
        return "bg-green-500/20 text-green-400 border-green-500/30";
      case "uploading":
      case "downloading":
        return "bg-blue-500/20 text-blue-400 border-blue-500/30";
      case "validating":
        return "bg-yellow-500/20 text-yellow-400 border-yellow-500/30";
      case "pending":
        return "bg-gray-500/20 text-gray-400 border-gray-500/30";
      case "error":
        return "bg-red-500/20 text-red-400 border-red-500/30";
      default:
        return "bg-gray-500/20 text-gray-400 border-gray-500/30";
    }
  };

  const getStatusText = () => {
    switch (status) {
      case "ready":
        return "Ready";
      case "uploading":
        return downloadProgress !== undefined
          ? `Uploading ${downloadProgress}%`
          : "Uploading";
      case "downloading":
        return downloadProgress !== undefined
          ? `Downloading ${downloadProgress}%`
          : "Downloading";
      case "validating":
        return "Validating";
      case "pending":
        return "Pending";
      case "error":
        return "Error";
      default:
        return status;
    }
  };

  return (
    <Badge variant="outline" className={`${getStatusColor()} border`}>
      {getStatusText()}
    </Badge>
  );
}
