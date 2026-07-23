"use client";

import Link from "next/link";
import { Shield } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  useAttachSecurityGroup,
  useDetachSecurityGroup,
  useSecurityGroups,
} from "@/lib/hooks/use-security-groups";
import { toast } from "sonner";
import type { SecurityGroup, VM, VMNetworkInterface } from "@/types/api";

/** All addresses of a NIC as `address/prefix`. */
function nicAddresses(nic: VMNetworkInterface): string[] {
  return (nic.addresses ?? []).map((a) => `${a.address}/${a.prefixLength}`);
}

/**
 * Guest-reported addresses (qga), as `address/prefix` — or just `address` when
 * the guest agent didn't supply a prefix length (issue #563).
 */
function nicObservedAddresses(nic: VMNetworkInterface): string[] {
  return (nic.observedAddresses ?? []).map((a) =>
    a.prefixLength != null ? `${a.address}/${a.prefixLength}` : a.address,
  );
}

function nicGateways(nic: VMNetworkInterface): string[] {
  return (nic.addresses ?? []).flatMap((a) => (a.gateway ? [a.gateway] : []));
}

/**
 * Attach/detach a security group on one NIC. The API doesn't expose which
 * groups a NIC currently attaches (only per-group attachment counts), so the
 * menu deliberately offers both actions for every group rather than
 * pretending to know membership; the server rejects no-op or invalid
 * combinations with a clear error.
 */
function NicSecurityGroupMenu({
  vm,
  nic,
  groups,
}: {
  vm: VM;
  nic: VMNetworkInterface;
  groups: SecurityGroup[];
}) {
  const attach = useAttachSecurityGroup();
  const detach = useDetachSecurityGroup();
  const busy = attach.isPending || detach.isPending;

  const handleAttach = (group: SecurityGroup) => {
    attach.mutate(
      { id: group.id, data: { vmId: vm.id, interfaceId: nic.id } },
      {
        onSuccess: () =>
          toast.success(`Attached "${group.name}" to ${nic.deviceName}`),
        onError: (error) =>
          toast.error(
            error instanceof Error
              ? error.message
              : "Failed to attach security group",
          ),
      },
    );
  };

  const handleDetach = (group: SecurityGroup) => {
    detach.mutate(
      { id: group.id, data: { vmId: vm.id, interfaceId: nic.id } },
      {
        onSuccess: () =>
          toast.success(`Detached "${group.name}" from ${nic.deviceName}`),
        onError: (error) =>
          toast.error(
            error instanceof Error
              ? error.message
              : "Failed to detach security group",
          ),
      },
    );
  };

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button
          size="sm"
          variant="ghost"
          className="text-foreground/80 hover:text-foreground hover:bg-accent"
          disabled={busy}
          title="Security groups"
        >
          <Shield className="h-4 w-4" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        <DropdownMenuLabel>Security groups</DropdownMenuLabel>
        <DropdownMenuSub>
          <DropdownMenuSubTrigger>Attach group</DropdownMenuSubTrigger>
          <DropdownMenuSubContent>
            {groups.map((group) => (
              <DropdownMenuItem
                key={group.id}
                onSelect={() => handleAttach(group)}
              >
                {group.name}
              </DropdownMenuItem>
            ))}
          </DropdownMenuSubContent>
        </DropdownMenuSub>
        <DropdownMenuSub>
          <DropdownMenuSubTrigger>Detach group</DropdownMenuSubTrigger>
          <DropdownMenuSubContent>
            {groups.map((group) => (
              <DropdownMenuItem
                key={group.id}
                onSelect={() => handleDetach(group)}
              >
                {group.name}
              </DropdownMenuItem>
            ))}
          </DropdownMenuSubContent>
        </DropdownMenuSub>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

export function VMNetworkCard({ vm }: { vm: VM }) {
  const interfaces = vm.networkInterfaces ?? [];
  const { data: securityGroups = [] } = useSecurityGroups(vm.projectId);
  const showSecurityGroups = securityGroups.length > 0;

  return (
    <Card className="bg-card border-border">
      <CardHeader>
        <CardTitle className="text-lg font-semibold text-foreground">
          Network Interfaces
        </CardTitle>
        {(vm.observedHostname || vm.qgaAvailable != null) && (
          <p className="text-sm text-muted-foreground">
            {vm.observedHostname ? (
              <>
                Guest hostname:{" "}
                <span className="font-mono text-foreground/80">
                  {vm.observedHostname}
                </span>
              </>
            ) : (
              "Guest agent connected"
            )}
          </p>
        )}
      </CardHeader>
      <CardContent>
        {interfaces.length === 0 ? (
          <div className="text-center py-6 text-muted-foreground">
            No network interfaces.
          </div>
        ) : (
          <Table>
            <TableHeader className="bg-background">
              <TableRow className="border-border hover:bg-transparent">
                <TableHead className="text-muted-foreground font-medium">
                  Device
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Network
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  MAC
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Addresses
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Observed (guest)
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Gateway
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  MTU
                </TableHead>
                {showSecurityGroups && (
                  <TableHead className="text-muted-foreground font-medium text-right">
                    Actions
                  </TableHead>
                )}
              </TableRow>
            </TableHeader>
            <TableBody className="divide-y divide-border">
              {interfaces.map((nic) => (
                <TableRow
                  key={nic.id ?? nic.deviceName}
                  className="border-border hover:bg-accent/60"
                >
                  <TableCell className="text-foreground/80 font-mono text-sm">
                    {nic.deviceName}
                  </TableCell>
                  <TableCell className="text-foreground/80">{nic.network}</TableCell>
                  <TableCell className="text-foreground/80 font-mono text-sm">
                    {nic.macAddress}
                  </TableCell>
                  <TableCell className="text-foreground/80 font-mono text-sm">
                    {nicAddresses(nic).length > 0
                      ? nicAddresses(nic).map((address) => (
                          <div key={address}>{address}</div>
                        ))
                      : "—"}
                  </TableCell>
                  <TableCell className="text-foreground/80 font-mono text-sm">
                    {nicObservedAddresses(nic).length > 0
                      ? nicObservedAddresses(nic).map((address) => (
                          <div key={address}>{address}</div>
                        ))
                      : "—"}
                  </TableCell>
                  <TableCell className="text-foreground/80 font-mono text-sm">
                    {nicGateways(nic).length > 0
                      ? nicGateways(nic).map((gateway) => (
                          <div key={gateway}>{gateway}</div>
                        ))
                      : "—"}
                  </TableCell>
                  <TableCell className="text-foreground/80">
                    {nic.mtu ?? "—"}
                  </TableCell>
                  {showSecurityGroups && (
                    <TableCell className="text-right">
                      {nic.id ? (
                        <NicSecurityGroupMenu
                          vm={vm}
                          nic={nic}
                          groups={securityGroups}
                        />
                      ) : null}
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
        {showSecurityGroups && (
          <p className="mt-3 text-xs text-muted-foreground">
            Every NIC belongs to at least one security group. Rules are managed
            on the{" "}
            <Link
              href="/security-groups"
              className="text-blue-600 hover:underline"
            >
              Security Groups
            </Link>{" "}
            page.
          </p>
        )}
      </CardContent>
    </Card>
  );
}
