"use client";

import { errorMessage } from "@/lib/errors";

import { confirmAction } from "@/providers/confirmation-provider";

import { useState } from "react";
import { Loader2, Pencil, Shield, Trash2 } from "lucide-react";
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
import { usePermissions } from "@/lib/hooks/use-permissions";
import type { ActionCheckItem, Network } from "@/types/api";

interface NetworkTableProps {
  networks: Network[];
  isLoading?: boolean;
  onRefresh?: () => void;
  onEdit?: (network: Network) => void;
  onManageACL?: (network: Network, canManage: boolean) => void;
}

export function NetworkTable({
  networks,
  isLoading,
  onRefresh,
  onEdit,
  onManageACL,
}: NetworkTableProps) {
  const [busyId, setBusyId] = useState<string | null>(null);
  const { permissions } = usePermissions(
    networks.flatMap((network): ActionCheckItem[] =>
      network.id
        ? [
            { key: `read:${network.id}`, action: "network:read", node: { type: "network", id: network.id } },
            { key: `update:${network.id}`, action: "network:update", node: { type: "network", id: network.id } },
            { key: `delete:${network.id}`, action: "network:delete", node: { type: "network", id: network.id } },
          ]
        : []
    )
  );

  const handleDelete = async (network: Network) => {
    if (!network.id) return;
    if (!await confirmAction(`Delete network "${network.name}"? This cannot be undone.`)) {
      return;
    }
    setBusyId(network.id);
    try {
      await networksApi.delete(network.id);
      toast.success(`Deleted network "${network.name}"`);
      onRefresh?.();
    } catch (error) {
      toast.error(
        errorMessage(error, "Failed to delete network")
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
          const deletable = !inUse;
          const canManageACL = Boolean(permissions[`update:${network.id}`]);
          const disabledReason = inUse
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
                {/* The badge reports addressing; the DNS line is outside it
                    because static networks carry resolvers too — cloud-init
                    delivers them at VM creation. */}
                <div className="space-y-0.5">
                  {network.dhcpEnabled ? (
                    <Badge className="bg-blue-500/15 text-blue-700 border-blue-300">
                      DHCP
                    </Badge>
                  ) : (
                    <Badge
                      variant="outline"
                      className="border-input text-muted-foreground"
                    >
                      Static
                    </Badge>
                  )}
                  <div className="text-xs text-muted-foreground font-mono">
                    {/* With the resolver on, these are its upstream forwarders
                        rather than what guests are told, so the label has to
                        say which reading applies (STR-40). */}
                    {network.resolverEnabled
                      ? network.dnsServers.length > 0
                        ? `resolver → ${network.dnsServers.join(", ")}`
                        : "resolver, no forwarders"
                      : network.dnsServers.length > 0
                        ? network.dnsServers.join(", ")
                        : "no DNS"}
                  </div>
                  {/* A network with a DNS zone attached whose guests are not
                      pointed at anything serving it (STR-201). Rendered in full
                      rather than truncated: the string names the remedy, and
                      the state is otherwise invisible — the zone realizes, the
                      resolver would answer, and the guest simply never asks. */}
                  {network.zoneResolutionWarning && (
                    <div className="text-xs text-amber-700 dark:text-amber-500 max-w-xs text-pretty">
                      {network.zoneResolutionWarning}
                    </div>
                  )}
                </div>
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
                  onClick={() => onManageACL?.(network, canManageACL)}
                  disabled={busyId === network.id}
                  title={canManageACL ? "Manage stateless network ACL" : "View stateless network ACL"}
                  aria-label={`${canManageACL ? "Manage" : "View"} ACL for ${network.name}`}
                  hidden={!permissions[`read:${network.id}`]}
                >
                  <Shield className="h-4 w-4" />
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  className="text-foreground/80 hover:text-foreground hover:bg-accent"
                  onClick={() => onEdit?.(network)}
                  disabled={busyId === network.id}
                  title="Edit gateway and DHCP settings"
                  aria-label={`Edit ${network.name}`}
                  hidden={!permissions[`update:${network.id}`]}
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
                  aria-label={`Delete ${network.name}`}
                  hidden={!permissions[`delete:${network.id}`]}
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
