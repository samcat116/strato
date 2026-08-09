"use client";

import {
  StatusBadge,
  type StatusBadgeConfig,
} from "@/components/ui/status-badge";
import type { VMStatus } from "@/types/api";

const statusConfig: Record<VMStatus, StatusBadgeConfig> = {
  Running: {
    label: "Running",
    className: "bg-green-500/20 text-green-600 border-green-500/30",
  },
  Shutdown: {
    label: "Stopped",
    className: "bg-red-500/20 text-red-600 border-red-500/30",
  },
  Paused: {
    label: "Paused",
    className: "bg-yellow-500/20 text-yellow-700 border-yellow-500/30",
  },
  Created: {
    label: "Created",
    className: "bg-blue-500/20 text-blue-600 border-blue-500/30",
  },
  Starting: {
    label: "Starting",
    className:
      "bg-green-500/20 text-green-600 border-green-500/30 animate-pulse",
  },
  Stopping: {
    label: "Stopping",
    className: "bg-red-500/20 text-red-600 border-red-500/30 animate-pulse",
  },
  Error: {
    label: "Error",
    className: "bg-red-500/20 text-red-600 border-red-500/30",
  },
  Unknown: {
    label: "Unknown",
    className: "bg-gray-500/20 text-muted-foreground border-gray-500/30",
  },
};

export function VMStatusBadge({
  status,
  vmId,
}: {
  status: VMStatus;
  /** When provided, an in-flight mutation on this VM overrides the status label. */
  vmId?: string;
}) {
  return <StatusBadge status={status} config={statusConfig} resourceId={vmId} />;
}
