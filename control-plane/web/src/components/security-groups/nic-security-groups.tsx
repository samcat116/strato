"use client";

import { Shield } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
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
  useAttachSecurityGroup,
  useDetachSecurityGroup,
} from "@/lib/hooks/use-security-groups";
import { toast } from "sonner";
import {
  MAX_SECURITY_GROUPS_PER_NIC,
  type AttachSecurityGroupRequest,
  type SecurityGroup,
} from "@/types/api";

/**
 * The bit of a NIC these components need, and nothing else. VM and sandbox
 * interfaces are different types server-side, but the security-group UI has
 * never depended on more than this (backend STR-102).
 */
export interface SecurityGroupNIC {
  id?: string;
  deviceName: string;
  securityGroupIds?: string[];
}

/**
 * The names of the groups filtering a NIC. An id with no matching group in the
 * project list is shown as the raw id rather than dropped — better a puzzling
 * id than a NIC that looks less filtered than it is.
 */
export function NicSecurityGroupNames({
  nic,
  groups,
}: {
  nic: SecurityGroupNIC;
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
 *
 * `target` is the whole difference between the VM and sandbox callers:
 * `{ vmId }` or `{ sandboxId }`. Everything else — the >=1-group floor, the
 * per-NIC cap, the copy — is identical, and duplicating it once meant two
 * places for it to drift.
 */
export function NicSecurityGroupMenu({
  target,
  nic,
  groups,
}: {
  target: Pick<AttachSecurityGroupRequest, "vmId" | "sandboxId">;
  nic: SecurityGroupNIC;
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
      { id: group.id, data: { ...target, interfaceId: nic.id } },
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
      { id: group.id, data: { ...target, interfaceId: nic.id } },
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
