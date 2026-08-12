"use client";

import Link from "next/link";
import { useState } from "react";
import { Loader2, Trash2 } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { CopyButton } from "@/components/ui/copy-button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  projectMemberErrorMessage,
  useBindableRoles,
  useRevokeProjectWorkload,
  useSetProjectWorkloadRole,
} from "@/lib/hooks";
import { warnAboutGrantCeilings } from "@/lib/grant-ceilings";
import type { ProjectVMPrincipal, ProjectWorkloadGrant } from "@/types/api";
import { toast } from "sonner";

interface VMGrantsTableProps {
  projectId: string;
  vms: ProjectVMPrincipal[];
  grants: ProjectWorkloadGrant[];
  isLoading?: boolean;
  canManage: boolean;
}

export function VMGrantsTable({
  projectId,
  vms,
  grants,
  isLoading,
  canManage,
}: VMGrantsTableProps) {
  const { data: roles = [], isLoading: rolesLoading } = useBindableRoles(
    "project",
    projectId
  );
  const setRole = useSetProjectWorkloadRole(projectId);
  const revoke = useRevokeProjectWorkload(projectId);
  const [pendingId, setPendingId] = useState<string | null>(null);
  const grantsByPrincipal = new Map(
    grants.map((grant) => [grant.registrationId, grant])
  );

  const handleRoleChange = async (vm: ProjectVMPrincipal, role: string) => {
    const principalId = vm.instanceIdentityPrincipalId;
    if (!principalId || role === grantsByPrincipal.get(principalId)?.role) return;
    const roleName = roles.find((candidate) => candidate.id === role)?.name ?? role;
    setPendingId(principalId);
    try {
      const result = await setRole.mutateAsync({
        registrationId: principalId,
        role,
      });
      toast.success(`Assigned the ${roleName} role to ${vm.name}`);
      warnAboutGrantCeilings(result, `${vm.name}'s ${roleName} role`);
    } catch (error) {
      toast.error(
        projectMemberErrorMessage(error, "Failed to update instance access")
      );
    } finally {
      setPendingId(null);
    }
  };

  const handleRevoke = async (
    vm: ProjectVMPrincipal,
    grant: ProjectWorkloadGrant
  ) => {
    if (!window.confirm(`Revoke ${vm.name}'s ${grant.roleDisplayName} role?`)) {
      return;
    }
    setPendingId(grant.registrationId);
    try {
      await revoke.mutateAsync(grant.registrationId);
      toast.success(`Revoked ${vm.name}'s project access`);
    } catch (error) {
      toast.error(
        projectMemberErrorMessage(error, "Failed to revoke instance access")
      );
    } finally {
      setPendingId(null);
    }
  };

  if (isLoading) {
    return (
      <div className="space-y-2">
        {[...Array(2)].map((_, index) => (
          <Skeleton key={index} className="h-14 w-full bg-muted" />
        ))}
      </div>
    );
  }

  if (vms.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        This project has no VMs to grant access to.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">VM</TableHead>
          <TableHead className="text-muted-foreground font-medium">Identity</TableHead>
          <TableHead className="text-muted-foreground font-medium">Role</TableHead>
          {canManage && (
            <TableHead className="text-muted-foreground font-medium text-right">
              Actions
            </TableHead>
          )}
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {vms.map((vm) => {
          const principalId = vm.instanceIdentityPrincipalId;
          const grant = principalId
            ? grantsByPrincipal.get(principalId)
            : undefined;
          const isPending = pendingId === principalId;
          const identityAvailable = !!principalId && !!vm.spiffeId;
          const identityRevoked = vm.instanceIdentityStatus === "revoked";

          return (
            <TableRow key={vm.id} className="border-border hover:bg-accent/60">
              <TableCell>
                <Link
                  href={`/vms/detail?id=${vm.id}`}
                  className="font-medium text-blue-600 hover:text-blue-700 hover:underline"
                >
                  {vm.name}
                </Link>
              </TableCell>
              <TableCell>
                {identityAvailable ? (
                  <div className="flex max-w-sm items-center gap-1">
                    <code className="truncate text-xs text-muted-foreground">
                      {vm.spiffeId}
                    </code>
                    <CopyButton
                      value={vm.spiffeId!}
                      label={`Copy ${vm.name}'s SPIFFE ID`}
                      toastMessage="SPIFFE ID copied"
                    />
                  </div>
                ) : (
                  <Badge
                    variant="outline"
                    className={
                      identityRevoked
                        ? "border-red-500/60 bg-red-500/10 text-red-700 dark:text-red-400"
                        : "border-border bg-muted text-muted-foreground"
                    }
                  >
                    {identityRevoked ? "Revoked" : "Unavailable"}
                  </Badge>
                )}
              </TableCell>
              <TableCell>
                {canManage && identityAvailable ? (
                  <Select
                    value={grant?.role}
                    onValueChange={(role) => handleRoleChange(vm, role)}
                    disabled={isPending || rolesLoading}
                  >
                    <SelectTrigger className="w-40 bg-background border-border text-foreground">
                      <SelectValue
                        placeholder={grant?.roleDisplayName ?? "No role"}
                      />
                    </SelectTrigger>
                    <SelectContent className="bg-card border-border">
                      {roles.map((role) => (
                        <SelectItem key={role.id} value={role.id}>
                          {role.name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                ) : grant ? (
                  <Badge variant="secondary">{grant.roleDisplayName}</Badge>
                ) : (
                  <span className="text-sm text-muted-foreground">No role</span>
                )}
              </TableCell>
              {canManage && (
                <TableCell className="text-right">
                  {grant && (
                    <Button
                      size="icon-sm"
                      variant="ghost"
                      className="text-muted-foreground hover:text-red-600 hover:bg-red-500/10"
                      onClick={() => handleRevoke(vm, grant)}
                      disabled={isPending}
                      aria-label={`Revoke ${vm.name}'s project role`}
                    >
                      {isPending ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <Trash2 className="h-4 w-4" />
                      )}
                    </Button>
                  )}
                </TableCell>
              )}
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
