import { Badge } from "@/components/ui/badge";
import type { AgentStatus } from "@/types/api";

const statusConfig: Record<AgentStatus, { label: string; className: string }> = {
  online: {
    label: "Online",
    className: "bg-green-500/20 text-green-400 border-green-500/30",
  },
  offline: {
    label: "Offline",
    className: "bg-red-500/20 text-red-400 border-red-500/30",
  },
  connecting: {
    label: "Connecting",
    className: "bg-yellow-500/20 text-yellow-400 border-yellow-500/30",
  },
  error: {
    label: "Error",
    className: "bg-red-500/20 text-red-400 border-red-500/30",
  },
};

export function AgentStatusBadge({ status }: { status: AgentStatus }) {
  const config = statusConfig[status] || statusConfig.offline;

  return (
    <Badge variant="outline" className={config.className}>
      {config.label}
    </Badge>
  );
}
