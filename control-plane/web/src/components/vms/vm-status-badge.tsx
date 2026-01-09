import { Badge } from "@/components/ui/badge";
import type { VMStatus } from "@/types/api";

const statusConfig: Record<
  VMStatus,
  { label: string; className: string }
> = {
  running: {
    label: "Running",
    className: "bg-green-500/20 text-green-400 border-green-500/30",
  },
  shutdown: {
    label: "Stopped",
    className: "bg-red-500/20 text-red-400 border-red-500/30",
  },
  paused: {
    label: "Paused",
    className: "bg-yellow-500/20 text-yellow-400 border-yellow-500/30",
  },
  created: {
    label: "Created",
    className: "bg-blue-500/20 text-blue-400 border-blue-500/30",
  },
};

export function VMStatusBadge({ status }: { status: VMStatus }) {
  const config = statusConfig[status] || statusConfig.created;

  return (
    <Badge variant="outline" className={config.className}>
      {config.label}
    </Badge>
  );
}
