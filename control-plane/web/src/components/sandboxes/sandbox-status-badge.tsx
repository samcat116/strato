"use client";

import {
  StatusBadge,
  type StatusBadgeConfig,
} from "@/components/ui/status-badge";
import type { SandboxStatus } from "@/types/api";

const statusConfig: Record<SandboxStatus, StatusBadgeConfig> = {
  Running: {
    label: "Running",
    className: "bg-green-500/20 text-green-600 border-green-500/30",
  },
  Stopped: {
    label: "Stopped",
    className: "bg-gray-500/20 text-muted-foreground border-gray-500/30",
  },
  Exited: {
    label: "Exited",
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

export function SandboxStatusBadge({
  status,
  sandboxId,
  exitCode,
}: {
  status: SandboxStatus;
  /** When provided, an in-flight mutation on this sandbox overrides the status label. */
  sandboxId?: string;
  /** Shown alongside the "Exited" label; a non-zero code is styled as a failure. */
  exitCode?: number | null;
}) {
  // A workload that exited non-zero reads as a failure; exit 0 stays neutral.
  // Folded into the config map (rather than short-circuiting the render) so an
  // in-flight mutation still takes priority over the exit label.
  const failed = exitCode != null && exitCode !== 0;
  const config =
    status === "Exited"
      ? {
          ...statusConfig,
          Exited: {
            label: exitCode != null ? `Exited (${exitCode})` : "Exited",
            className: failed
              ? "bg-red-500/20 text-red-600 border-red-500/30"
              : statusConfig.Exited.className,
          },
        }
      : statusConfig;

  return (
    <StatusBadge status={status} config={config} resourceId={sandboxId} />
  );
}
