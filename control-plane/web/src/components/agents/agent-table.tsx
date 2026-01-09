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
          <Skeleton key={i} className="h-12 w-full bg-gray-700" />
        ))}
      </div>
    );
  }

  if (agents.length === 0) {
    return (
      <div className="text-center py-8 text-gray-400">
        No agents registered. Create a registration token to add an agent.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-gray-900">
        <TableRow className="border-gray-700 hover:bg-gray-900">
          <TableHead className="text-gray-400 font-medium">Name</TableHead>
          <TableHead className="text-gray-400 font-medium">Status</TableHead>
          <TableHead className="text-gray-400 font-medium">Hostname</TableHead>
          <TableHead className="text-gray-400 font-medium">CPU</TableHead>
          <TableHead className="text-gray-400 font-medium">Memory</TableHead>
          <TableHead className="text-gray-400 font-medium">
            Last Heartbeat
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-gray-700">
        {agents.map((agent) => (
          <TableRow
            key={agent.id}
            className="border-gray-700 hover:bg-gray-800/50"
          >
            <TableCell>
              <span className="font-medium text-gray-100">{agent.name}</span>
              <p className="text-sm text-gray-500">v{agent.version}</p>
            </TableCell>
            <TableCell>
              <AgentStatusBadge
                status={agent.isOnline ? "online" : "offline"}
              />
            </TableCell>
            <TableCell className="text-gray-300">{agent.hostname}</TableCell>
            <TableCell className="text-gray-300">
              {agent.resources.availableCPU} / {agent.resources.totalCPU} cores
            </TableCell>
            <TableCell className="text-gray-300">
              {Math.round(agent.resources.availableMemory / 1024)} /{" "}
              {Math.round(agent.resources.totalMemory / 1024)} GB
            </TableCell>
            <TableCell className="text-gray-400 text-sm">
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
