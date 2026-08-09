import {
  StatusBadge,
  type StatusBadgeConfig,
} from "@/components/ui/status-badge";
import type { SnapshotStatus } from "@/types/api";

const statusConfig: Record<SnapshotStatus, StatusBadgeConfig> = {
  creating: {
    label: "Creating",
    className: "bg-blue-500/20 text-blue-600 border-blue-500/30 animate-pulse",
  },
  available: {
    label: "Available",
    className: "bg-green-500/20 text-green-600 border-green-500/30",
  },
  restoring: {
    label: "Restoring",
    className:
      "bg-yellow-500/20 text-yellow-700 border-yellow-500/30 animate-pulse",
  },
  deleting: {
    label: "Deleting",
    className: "bg-red-500/20 text-red-600 border-red-500/30 animate-pulse",
  },
  error: {
    label: "Error",
    className: "bg-red-500/20 text-red-600 border-red-500/30",
  },
};

// No resourceId is passed, so this badge has no pending-mutation override —
// the snapshot table communicates in-flight deletes through `status` alone.
export function SnapshotStatusBadge({ status }: { status: SnapshotStatus }) {
  return <StatusBadge status={status} config={statusConfig} />;
}
