"use client";

import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Skeleton } from "@/components/ui/skeleton";
import { Badge } from "@/components/ui/badge";
import { AgentStatusBadge } from "./agent-status-badge";
import { AgentUpdateAction } from "./agent-update-action";
import { useOrganization } from "@/providers/organization-provider";
import type { Agent } from "@/types/api";

interface AgentTableProps {
  agents: Agent[];
  isLoading?: boolean;
}

export function AgentTable({ agents, isLoading }: AgentTableProps) {
  const { organizations } = useOrganization();

  // Agents are dedicated to an org (or an OU within one); resolve names for
  // orgs the viewer can see, fall back to a shortened id otherwise.
  const ownerLabel = (agent: Agent) => {
    if (agent.organizationId) {
      const org = organizations.find((o) => o.id === agent.organizationId);
      return org?.name ?? `${agent.organizationId.slice(0, 8)}…`;
    }
    if (agent.organizationalUnitId) {
      return `OU ${agent.organizationalUnitId.slice(0, 8)}…`;
    }
    return "—";
  };

  if (isLoading) {
    return (
      <div className="space-y-2">
        {[...Array(3)].map((_, i) => (
          <Skeleton key={i} className="h-12 w-full bg-muted" />
        ))}
      </div>
    );
  }

  if (agents.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        No agents registered. Create a registration token to add an agent.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">Name</TableHead>
          <TableHead className="text-muted-foreground font-medium">Status</TableHead>
          <TableHead className="text-muted-foreground font-medium">Organization</TableHead>
          <TableHead className="text-muted-foreground font-medium">Hostname</TableHead>
          <TableHead className="text-muted-foreground font-medium">CPU</TableHead>
          <TableHead className="text-muted-foreground font-medium">Memory</TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Last Heartbeat
          </TableHead>
          <TableHead className="w-0">
            <span className="sr-only">Actions</span>
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {agents.map((agent) => (
          <TableRow
            key={agent.id}
            className="border-border hover:bg-accent/60"
          >
            <TableCell>
              <span className="font-medium text-foreground">{agent.name}</span>
              <p className="text-sm text-muted-foreground flex items-center gap-1.5">
                {agent.version}
                {agent.updateAvailable && (
                  <Badge
                    variant="outline"
                    className="border-amber-500/50 text-amber-600 dark:text-amber-400"
                    title={
                      agent.targetVersion
                        ? `Update available: ${agent.targetVersion}`
                        : "Update available"
                    }
                  >
                    Update available
                  </Badge>
                )}
              </p>
            </TableCell>
            <TableCell>
              <AgentStatusBadge
                status={agent.isOnline ? "online" : "offline"}
              />
            </TableCell>
            <TableCell className="text-foreground/80">{ownerLabel(agent)}</TableCell>
            <TableCell className="text-foreground/80">{agent.hostname}</TableCell>
            <TableCell className="text-foreground/80">
              {agent.resources.availableCPU} / {agent.resources.totalCPU} cores
            </TableCell>
            <TableCell className="text-foreground/80">
              {Math.round(agent.resources.availableMemory / 1024 / 1024 / 1024)} /{" "}
              {Math.round(agent.resources.totalMemory / 1024 / 1024 / 1024)} GB
            </TableCell>
            <TableCell className="text-muted-foreground text-sm">
              {agent.lastHeartbeat
                ? new Date(agent.lastHeartbeat).toLocaleString()
                : "Never"}
            </TableCell>
            <TableCell className="text-right">
              <AgentUpdateAction agent={agent} size="sm" />
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
