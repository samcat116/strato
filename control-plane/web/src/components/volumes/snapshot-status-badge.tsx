import { Badge } from "@/components/ui/badge";
import type { SnapshotStatus } from "@/types/api";

const statusConfig: Record<
  SnapshotStatus,
  { label: string; className: string }
> = {
  creating: {
    label: "Creating",
    className: "bg-blue-500/20 text-blue-400 border-blue-500/30 animate-pulse",
  },
  available: {
    label: "Available",
    className: "bg-green-500/20 text-green-400 border-green-500/30",
  },
  restoring: {
    label: "Restoring",
    className:
      "bg-yellow-500/20 text-yellow-400 border-yellow-500/30 animate-pulse",
  },
  deleting: {
    label: "Deleting",
    className: "bg-red-500/20 text-red-400 border-red-500/30 animate-pulse",
  },
  error: {
    label: "Error",
    className: "bg-red-500/20 text-red-400 border-red-500/30",
  },
};

const unknownConfig = {
  label: "Unknown",
  className: "bg-gray-500/20 text-gray-400 border-gray-500/30",
};

export function SnapshotStatusBadge({ status }: { status: SnapshotStatus }) {
  const config = statusConfig[status] || unknownConfig;

  return (
    <Badge variant="outline" className={config.className}>
      {config.label}
    </Badge>
  );
}
