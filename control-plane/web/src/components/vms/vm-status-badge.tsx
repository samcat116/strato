"use client";

import { Badge } from "@/components/ui/badge";
import { usePendingOperation } from "@/lib/stores/operations-store";
import type { VMStatus, OperationKind } from "@/types/api";

const statusConfig: Record<
  VMStatus,
  { label: string; className: string }
> = {
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

// Labels for VM states that only exist as an in-flight operation (the server
// keeps the VM's resting status until the agent confirms).
const pendingOperationLabels: Record<OperationKind, string> = {
  create: "Creating",
  boot: "Starting",
  shutdown: "Stopping",
  reboot: "Restarting",
  pause: "Pausing",
  resume: "Resuming",
  delete: "Deleting",
  // Sandbox-only kinds; VMs never carry them but the map stays total.
  snapshot: "Snapshotting",
  snapshot_delete: "Deleting snapshot",
  restore: "Restoring",
};

export function VMStatusBadge({
  status,
  vmId,
}: {
  status: VMStatus;
  /** When provided, an in-flight operation on this VM overrides the status label. */
  vmId?: string;
}) {
  const pendingOperation = usePendingOperation(vmId);

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

  return (
    <Badge variant="outline" className={config.className}>
      {config.label}
    </Badge>
  );
}
