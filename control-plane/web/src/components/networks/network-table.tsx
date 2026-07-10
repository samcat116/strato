"use client";

import { useState } from "react";
import { Loader2, Pencil, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Skeleton } from "@/components/ui/skeleton";
import { networksApi } from "@/lib/api/networks";
import { toast } from "sonner";
import type { Network } from "@/types/api";

interface NetworkTableProps {
  networks: Network[];
  isLoading?: boolean;
  onRefresh?: () => void;
  onEdit?: (network: Network) => void;
}

export function NetworkTable({
  networks,
  isLoading,
  onRefresh,
  onEdit,
}: NetworkTableProps) {
  const [busyId, setBusyId] = useState<string | null>(null);

  const handleDelete = async (network: Network) => {
    if (!network.id) return;
    if (!confirm(`Delete network "${network.name}"? This cannot be undone.`)) {
      return;
    }
    setBusyId(network.id);
    try {
      await networksApi.delete(network.id);
      toast.success(`Deleted network "${network.name}"`);
      onRefresh?.();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to delete network"
      );
    } finally {
      setBusyId(null);
    }
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

  if (networks.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        No networks found. Create one to get started.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">Name</TableHead>
          <TableHead className="text-muted-foreground font-medium">Subnet</TableHead>
          <TableHead className="text-muted-foreground font-medium">Gateway</TableHead>
          <TableHead className="text-muted-foreground font-medium">DHCP / DNS</TableHead>
          <TableHead className="text-muted-foreground font-medium">Scope</TableHead>
          <TableHead className="text-muted-foreground font-medium">Interfaces</TableHead>
          <TableHead className="text-muted-foreground font-medium text-right">
            Actions
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {networks.map((network) => {
          const inUse = network.attachedInterfaceCount > 0;
          const deletable = !network.isDefault && !inUse;
          const disabledReason = network.isDefault
            ? "The default network cannot be deleted"
            : inUse
              ? "Detach all interfaces before deleting"
              : undefined;
          return (
            <TableRow
              key={network.id}
              className="border-border hover:bg-accent/60"
            >
              <TableCell>
                <span className="font-medium text-foreground">
                  {network.name}
                </span>
                {network.isDefault && (
                  <Badge
                    variant="outline"
                    className="ml-2 border-input text-muted-foreground"
                  >
                    default
                  </Badge>
                )}
              </TableCell>
              <TableCell className="text-foreground/80 font-mono text-sm">
                <div>{network.subnet}</div>
                {network.subnet6 && (
                  <div className="text-xs text-muted-foreground">
                    {network.subnet6}
                  </div>
                )}
              </TableCell>
              <TableCell className="text-foreground/80 font-mono text-sm">
                <div>{network.gateway ?? "—"}</div>
                {network.gateway6 && (
                  <div className="text-xs text-muted-foreground">
                    {network.gateway6}
                  </div>
                )}
              </TableCell>
              <TableCell className="text-foreground/80 text-sm">
                {network.dhcpEnabled ? (
                  <div className="space-y-0.5">
                    <Badge className="bg-blue-500/15 text-blue-700 border-blue-300">
                      DHCP
                    </Badge>
                    <div className="text-xs text-muted-foreground font-mono">
                      {network.dnsServers.length > 0
                        ? network.dnsServers.join(", ")
                        : "no DNS"}
                    </div>
                  </div>
                ) : (
                  <Badge
                    variant="outline"
                    className="border-input text-muted-foreground"
                  >
                    Static
                  </Badge>
                )}
              </TableCell>
              <TableCell className="text-foreground/80">
                {network.projectId ? "Project" : "Global"}
              </TableCell>
              <TableCell className="text-foreground/80">
                {network.attachedInterfaceCount}
              </TableCell>
              <TableCell className="text-right">
                <Button
                  size="sm"
                  variant="ghost"
                  className="text-foreground/80 hover:text-foreground hover:bg-accent"
                  onClick={() => onEdit?.(network)}
                  disabled={busyId === network.id}
                  title="Edit gateway and DHCP settings"
                >
                  <Pencil className="h-4 w-4" />
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  className="text-red-600 hover:text-red-700 hover:bg-red-500/10"
                  onClick={() => handleDelete(network)}
                  disabled={!deletable || busyId === network.id}
                  title={disabledReason}
                >
                  {busyId === network.id ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <Trash2 className="h-4 w-4" />
                  )}
                </Button>
              </TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
