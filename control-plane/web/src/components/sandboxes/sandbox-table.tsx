"use client";

import Link from "next/link";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Skeleton } from "@/components/ui/skeleton";
import { SandboxStatusBadge } from "./sandbox-status-badge";
import { SandboxActions } from "./sandbox-actions";
import { formatMemory } from "./format";
import type { Sandbox } from "@/types/api";

interface SandboxTableProps {
  sandboxes: Sandbox[];
  isLoading?: boolean;
  onRefresh?: () => void;
}

export function SandboxTable({
  sandboxes,
  isLoading,
  onRefresh,
}: SandboxTableProps) {
  if (isLoading) {
    return (
      <div className="space-y-2">
        {[...Array(3)].map((_, i) => (
          <Skeleton key={i} className="h-12 w-full bg-muted" />
        ))}
      </div>
    );
  }

  if (sandboxes.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        No sandboxes found. Create one to get started.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">Name</TableHead>
          <TableHead className="text-muted-foreground font-medium">Status</TableHead>
          <TableHead className="text-muted-foreground font-medium">Image</TableHead>
          <TableHead className="text-muted-foreground font-medium">vCPUs</TableHead>
          <TableHead className="text-muted-foreground font-medium">Memory</TableHead>
          <TableHead className="text-muted-foreground font-medium text-right">
            Actions
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {sandboxes.map((sandbox) => (
          <TableRow
            key={sandbox.id}
            className="border-border hover:bg-accent/60 cursor-pointer"
          >
            <TableCell>
              <Link
                href={`/sandboxes/detail?id=${sandbox.id}`}
                className="font-medium text-foreground hover:text-blue-700"
              >
                {sandbox.name}
              </Link>
            </TableCell>
            <TableCell>
              <SandboxStatusBadge
                status={sandbox.status}
                sandboxId={sandbox.id}
                exitCode={sandbox.exitCode}
              />
            </TableCell>
            <TableCell className="text-foreground/80 font-mono text-xs truncate max-w-xs">
              {sandbox.image}
            </TableCell>
            <TableCell className="text-foreground/80">{sandbox.cpus}</TableCell>
            <TableCell className="text-foreground/80">
              {formatMemory(sandbox.memory)}
            </TableCell>
            <TableCell className="text-right">
              <SandboxActions sandbox={sandbox} onActionComplete={onRefresh} />
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
