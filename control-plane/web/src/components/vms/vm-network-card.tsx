"use client";

import Link from "next/link";
import { AlertTriangle, Shield } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
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
import {
  MAX_SECURITY_GROUPS_PER_NIC,
  type SecurityGroup,
  type VM,
  type VMNetworkInterface,
} from "@/types/api";

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
 * The names of the groups filtering a NIC. An id with no matching group in the
 * project list is shown as the raw id rather than dropped — better a puzzling
 * id than a NIC that looks less filtered than it is.
 */
function NicSecurityGroupNames({
  nic,
  groups,
}: {
  nic: VMNetworkInterface;
  groups: SecurityGroup[];
}) {
  if (!nic.securityGroupIds) {
    return <span className="text-muted-foreground">—</span>;
  }
  if (nic.securityGroupIds.length === 0) {
    // The server holds every NIC to >=1 group, so this is an anomaly worth
    // showing rather than a blank cell. It does *not* mean unfiltered: a NIC
    // with no groups is unmanaged — the sync omits the field, the agent reads
    // that as "no opinion", and the port keeps whatever OVN membership it
    // already had. Saying "unfiltered" would send debugging the wrong way.
    return (
      <Badge
        variant="secondary"
        className="font-normal text-amber-700 dark:text-amber-400"
        title="No groups recorded. The port keeps its existing dataplane membership until a group is attached."
      >
        no groups
      </Badge>
    );
  }
  return (
    <div className="flex flex-wrap gap-1">
      {nic.securityGroupIds.map((id) => (
        <Badge key={id} variant="secondary" className="font-normal">
          {groups.find((group) => group.id === id)?.name ?? id}
        </Badge>
      ))}
    </div>
  );
}

/**
 * Attach/detach a NIC's security groups as one checkbox list: checked groups
 * are attached, and toggling one attaches or detaches it.
 *
 * When the server doesn't report membership (`securityGroupIds` undefined — an
 * older control plane) the menu falls back to offering attach and detach
 * separately, since a checkbox list with nothing checked would claim the NIC
 * is in no group. The server still validates either way; the disabled states
 * below only spare the user a round trip for refusals we can predict.
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
  const attached = nic.securityGroupIds;
  const atCap = (attached?.length ?? 0) >= MAX_SECURITY_GROUPS_PER_NIC;
  // The server refuses to empty a NIC's group set, so the last one can't go.
  const isLastGroup = attached?.length === 1;

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
        {attached ? (
          groups.map((group) => {
            const isAttached = attached.includes(group.id);
            return (
              <DropdownMenuCheckboxItem
                key={group.id}
                checked={isAttached}
                disabled={isAttached ? isLastGroup : atCap}
                // Radix would otherwise close and reopen focus mid-mutation.
                onSelect={(event) => event.preventDefault()}
                onCheckedChange={() =>
                  isAttached ? handleDetach(group) : handleAttach(group)
                }
              >
                {group.name}
              </DropdownMenuCheckboxItem>
            );
          })
        ) : (
          <>
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
          </>
        )}
        {atCap && attached && (
          <p className="px-2 py-1.5 text-xs text-muted-foreground">
            At the {MAX_SECURITY_GROUPS_PER_NIC}-group limit; detach one first.
          </p>
        )}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

export function VMNetworkCard({ vm }: { vm: VM }) {
  const interfaces = vm.networkInterfaces ?? [];
  const {
    data: securityGroups = [],
    isError: securityGroupsFailed,
  } = useSecurityGroups(vm.projectId);
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
        {vm.securityGroupsEnforced === false && (
          // Not a nicety: without this the UI shows attached groups on a host
          // that ignores them entirely, which reads as "filtered" when it
          // isn't. Derived server-side — listing agents is admin-only, so a
          // project user could never work this out from the agent's version.
          <div className="mb-3 flex items-start gap-2 rounded-md border border-amber-500/40 bg-amber-500/10 p-3 text-sm text-amber-700 dark:text-amber-400">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
            <span>
              Security groups are <strong>not enforced</strong> on this VM&apos;s
              host: the agent realizing it predates security-group support, so
              the groups below filter nothing. Upgrade the agent to enforce
              them.
            </span>
          </div>
        )}
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
                  <>
                    <TableHead className="text-muted-foreground font-medium">
                      Security groups
                    </TableHead>
                    <TableHead className="text-muted-foreground font-medium text-right">
                      Actions
                    </TableHead>
                  </>
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
                  <TableCell className="text-foreground/80">
                    {nic.network ?? nic.networkId}
                  </TableCell>
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
                    <>
                      <TableCell>
                        <NicSecurityGroupNames
                          nic={nic}
                          groups={securityGroups}
                        />
                      </TableCell>
                      <TableCell className="text-right">
                        {nic.id ? (
                          <NicSecurityGroupMenu
                            vm={vm}
                            nic={nic}
                            groups={securityGroups}
                          />
                        ) : null}
                      </TableCell>
                    </>
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
        {securityGroupsFailed && (
          // A failed fetch must not silently hide the security-group UI as if
          // no groups existed.
          <p className="mt-3 text-xs text-red-600">
            Failed to load security groups; attach/detach is unavailable until
            the page is refreshed.
          </p>
        )}
      </CardContent>
    </Card>
  );
}
