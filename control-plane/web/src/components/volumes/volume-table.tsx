"use client";

import { useMemo } from "react";
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
import { VolumeStatusBadge } from "./volume-status-badge";
import { VolumeSize } from "./volume-size";
import { VolumeActions } from "./volume-actions";
import { usePermissions } from "@/lib/hooks/use-permissions";
import type { ActionCheckItem, VM, Volume } from "@/types/api";

interface VolumeTableProps {
  volumes: Volume[];
  vms: VM[];
  isLoading?: boolean;
  onRefresh?: () => void;
}

export function VolumeTable({
  volumes,
  vms,
  isLoading,
  onRefresh,
}: VolumeTableProps) {
  const actionChecks = [
    ["attach", "volume:attach"],
    ["detach", "volume:detach"],
    ["resize", "volume:update"],
    ["snapshot", "volume:snapshot"],
    ["clone", "volume:clone"],
    ["delete", "volume:delete"],
  ] as const;
  const { permissions } = usePermissions(volumes.flatMap((volume): ActionCheckItem[] =>
    volume.id ? actionChecks.map(([key, action]) => ({ key: `${volume.id}:${key}`, action, node: { type: "volume", id: volume.id! } })) : []
  ));
  const vmsById = useMemo(
    () => new Map(vms.map((vm) => [vm.id, vm])),
    [vms]
  );

  if (isLoading) {
    return (
      <div className="space-y-2">
        {[...Array(3)].map((_, i) => (
          <Skeleton key={i} className="h-12 w-full bg-muted" />
        ))}
      </div>
    );
  }

  if (volumes.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        No volumes found. Create one to get started.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">Name</TableHead>
          <TableHead className="text-muted-foreground font-medium">Status</TableHead>
          <TableHead className="text-muted-foreground font-medium">Type</TableHead>
          <TableHead className="text-muted-foreground font-medium">Size</TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Attached To
          </TableHead>
          <TableHead className="text-muted-foreground font-medium text-right">
            Actions
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {volumes.map((volume) => {
          const attachedVM = volume.vmId ? vmsById.get(volume.vmId) : undefined;
          return (
            <TableRow
              key={volume.id}
              className="border-border hover:bg-accent/60"
            >
              <TableCell>
                <span className="font-medium text-foreground">{volume.name}</span>
                {volume.description && (
                  <p className="text-sm text-muted-foreground truncate max-w-xs">
                    {volume.description}
                  </p>
                )}
                {volume.status === "error" && volume.errorMessage && (
                  <p className="text-sm text-red-600 truncate max-w-xs">
                    {volume.errorMessage}
                  </p>
                )}
              </TableCell>
              <TableCell>
                <VolumeStatusBadge status={volume.status} volumeId={volume.id} />
              </TableCell>
              <TableCell className="text-foreground/80">
                {volume.volumeType}
                <span className="text-muted-foreground"> · {volume.format}</span>
                <p className="text-xs text-muted-foreground">
                  Block: {volume.blockMode}
                  {volume.appliedBlockPolicy?.active && (
                    <>
                      {" · "}
                      {volume.appliedBlockPolicy.cacheMode ?? "default cache"}
                      {volume.appliedBlockPolicy.ioMode
                        ? `/${volume.appliedBlockPolicy.ioMode}`
                        : ""}
                      {volume.appliedBlockPolicy.queueCount
                        ? ` · ${volume.appliedBlockPolicy.queueCount} queues`
                        : ""}
                    </>
                  )}
                </p>
                {volume.appliedBlockPolicy?.fallbackReason && (
                  <p
                    className="max-w-xs text-xs text-amber-700"
                    title={volume.appliedBlockPolicy.fallbackReason}
                  >
                    {volume.appliedBlockPolicy.fallbackReason}
                  </p>
                )}
              </TableCell>
              <TableCell className="text-foreground/80">
                <VolumeSize volume={volume} />
              </TableCell>
              <TableCell>
                {attachedVM ? (
                  <Link
                    href={`/vms/${attachedVM.id}`}
                    className="text-blue-600 hover:text-blue-700 hover:underline"
                  >
                    {attachedVM.name}
                    {volume.deviceName && (
                      <span className="text-muted-foreground">
                        {" "}
                        ({volume.deviceName})
                      </span>
                    )}
                  </Link>
                ) : volume.vmId ? (
                  <span className="text-foreground/80 font-mono text-sm">
                    {volume.vmId}
                  </span>
                ) : (
                  <span className="text-muted-foreground">—</span>
                )}
              </TableCell>
              <TableCell className="text-right">
                <VolumeActions volume={volume} onActionComplete={onRefresh} allowedActions={Object.fromEntries(actionChecks.map(([key]) => [key, permissions[`${volume.id}:${key}`]]))} />
              </TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
