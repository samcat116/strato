"use client";

import { Badge } from "@/components/ui/badge";
import { usePendingOperation } from "@/lib/stores/operations-store";
import type { SandboxStatus, OperationKind } from "@/types/api";

const statusConfig: Record<SandboxStatus, { label: string; className: string }> =
  {
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

// Labels for sandbox states that only exist as an in-flight operation (the
// server keeps the sandbox's resting status until the agent confirms). Sandboxes
// never pause/resume, but the map covers every OperationKind for exhaustiveness.
const pendingOperationLabels: Record<OperationKind, string> = {
  create: "Creating",
  boot: "Starting",
  shutdown: "Stopping",
  reboot: "Restarting",
  pause: "Pausing",
  resume: "Resuming",
  delete: "Deleting",
  resize: "Resizing",
  snapshot: "Snapshotting",
  snapshot_delete: "Deleting snapshot",
  restore: "Restoring",
  snapshot_export: "Exporting snapshot",
};

export function SandboxStatusBadge({
  status,
  sandboxId,
  exitCode,
}: {
  status: SandboxStatus;
  /** When provided, an in-flight operation on this sandbox overrides the status label. */
  sandboxId?: string;
  /** Shown alongside the "Exited" label; a non-zero code is styled as a failure. */
  exitCode?: number | null;
}) {
  const pendingOperation = usePendingOperation(sandboxId);

  if (pendingOperation) {
    return (
      <Badge
        variant="outline"
        className="bg-blue-500/20 text-blue-600 border-blue-500/30 animate-pulse"
      >
        {pendingOperationLabels[pendingOperation.kind]}
      </Badge>
    );
  }

  const config = statusConfig[status] || statusConfig.Unknown;

  // A workload that exited non-zero reads as a failure; exit 0 stays neutral.
  if (status === "Exited") {
    const failed = exitCode != null && exitCode !== 0;
    return (
      <Badge
        variant="outline"
        className={
          failed
            ? "bg-red-500/20 text-red-600 border-red-500/30"
            : config.className
        }
      >
        {exitCode != null ? `Exited (${exitCode})` : "Exited"}
      </Badge>
    );
  }

  return (
    <Badge variant="outline" className={config.className}>
      {config.label}
    </Badge>
  );
}
