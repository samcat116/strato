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
import { AgentStatusBadge } from "./agent-status-badge";
import type { Agent } from "@/types/api";

interface AgentTableProps {
  agents: Agent[];
  isLoading?: boolean;
}

export function AgentTable({ agents, isLoading }: AgentTableProps) {
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
          <TableHead className="text-muted-foreground font-medium">Hostname</TableHead>
          <TableHead className="text-muted-foreground font-medium">CPU</TableHead>
          <TableHead className="text-muted-foreground font-medium">Memory</TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Last Heartbeat
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
              <p className="text-sm text-muted-foreground">v{agent.version}</p>
            </TableCell>
            <TableCell>
              <AgentStatusBadge
                status={agent.isOnline ? "online" : "offline"}
              />
            </TableCell>
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
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
