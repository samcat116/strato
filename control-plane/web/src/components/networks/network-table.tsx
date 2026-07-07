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
          <Skeleton key={i} className="h-12 w-full bg-gray-700" />
        ))}
      </div>
    );
  }

  if (networks.length === 0) {
    return (
      <div className="text-center py-8 text-gray-400">
        No networks found. Create one to get started.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-gray-900">
        <TableRow className="border-gray-700 hover:bg-gray-900">
          <TableHead className="text-gray-400 font-medium">Name</TableHead>
          <TableHead className="text-gray-400 font-medium">Subnet</TableHead>
          <TableHead className="text-gray-400 font-medium">Gateway</TableHead>
          <TableHead className="text-gray-400 font-medium">DHCP / DNS</TableHead>
          <TableHead className="text-gray-400 font-medium">Scope</TableHead>
          <TableHead className="text-gray-400 font-medium">Interfaces</TableHead>
          <TableHead className="text-gray-400 font-medium text-right">
            Actions
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-gray-700">
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
              className="border-gray-700 hover:bg-gray-800/50"
            >
              <TableCell>
                <span className="font-medium text-gray-100">
                  {network.name}
                </span>
                {network.isDefault && (
                  <Badge
                    variant="outline"
                    className="ml-2 border-gray-600 text-gray-400"
                  >
                    default
                  </Badge>
                )}
              </TableCell>
              <TableCell className="text-gray-300 font-mono text-sm">
                {network.subnet}
              </TableCell>
              <TableCell className="text-gray-300 font-mono text-sm">
                {network.gateway ?? "—"}
              </TableCell>
              <TableCell className="text-gray-300 text-sm">
                {network.dhcpEnabled ? (
                  <div className="space-y-0.5">
                    <Badge className="bg-blue-600/20 text-blue-300 border-blue-700">
                      DHCP
                    </Badge>
                    <div className="text-xs text-gray-400 font-mono">
                      {network.dnsServers.length > 0
                        ? network.dnsServers.join(", ")
                        : "no DNS"}
                    </div>
                  </div>
                ) : (
                  <Badge
                    variant="outline"
                    className="border-gray-600 text-gray-400"
                  >
                    Static
                  </Badge>
                )}
              </TableCell>
              <TableCell className="text-gray-300">
                {network.projectId ? "Project" : "Global"}
              </TableCell>
              <TableCell className="text-gray-300">
                {network.attachedInterfaceCount}
              </TableCell>
              <TableCell className="text-right">
                <Button
                  size="sm"
                  variant="ghost"
                  className="text-gray-300 hover:text-gray-100 hover:bg-gray-700"
                  onClick={() => onEdit?.(network)}
                  disabled={busyId === network.id}
                  title="Edit gateway and DHCP settings"
                >
                  <Pencil className="h-4 w-4" />
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  className="text-red-400 hover:text-red-300 hover:bg-red-500/10"
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
