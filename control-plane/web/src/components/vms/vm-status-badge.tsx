import { Badge } from "@/components/ui/badge";
import type { VMStatus } from "@/types/api";

const statusConfig: Record<
  VMStatus,
  { label: string; className: string }
> = {
  Running: {
    label: "Running",
    className: "bg-green-500/20 text-green-400 border-green-500/30",
  },
  Shutdown: {
    label: "Stopped",
    className: "bg-red-500/20 text-red-400 border-red-500/30",
  },
  Paused: {
    label: "Paused",
    className: "bg-yellow-500/20 text-yellow-400 border-yellow-500/30",
  },
  Created: {
    label: "Created",
    className: "bg-blue-500/20 text-blue-400 border-blue-500/30",
  },
};

export function VMStatusBadge({ status }: { status: VMStatus }) {
  const config = statusConfig[status] || statusConfig.Created;

  return (
    <Badge variant="outline" className={config.className}>
      {config.label}
    </Badge>
  );
}
