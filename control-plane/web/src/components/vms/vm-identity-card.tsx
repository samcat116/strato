"use client";

import { useMemo } from "react";
import {
  CircleHelp,
  Fingerprint,
  Loader2,
  ShieldCheck,
  ShieldOff,
  Trash2,
} from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { CopyButton } from "@/components/ui/copy-button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  projectMemberErrorMessage,
  useBindableRoles,
  usePermissions,
  useProjectMembers,
  useRevokeProjectWorkload,
  useSetProjectWorkloadRole,
} from "@/lib/hooks";
import { warnAboutGrantCeilings } from "@/lib/grant-ceilings";
import type { VM } from "@/types/api";
import { toast } from "sonner";

interface VMIdentityCardProps {
  vm: VM;
}

export function VMIdentityCard({ vm }: VMIdentityCardProps) {
  const projectId = vm.projectId ?? "";
  const { data: members, isLoading: membersLoading } =
    useProjectMembers(projectId);
  const { data: roles = [], isLoading: rolesLoading } = useBindableRoles(
    "project",
    projectId
  );
  const { permissions } = usePermissions(
    projectId
      ? [
          {
            key: "set_policy",
            action: "iam:setPolicy",
            node: { type: "project", id: projectId },
          },
        ]
      : []
  );
  const setRole = useSetProjectWorkloadRole(projectId);
  const revoke = useRevokeProjectWorkload(projectId);

  const grant = useMemo(
    () =>
      members?.workloads?.find(
        (candidate) =>
          candidate.registrationId === vm.instanceIdentityPrincipalId
      ),
    [members?.workloads, vm.instanceIdentityPrincipalId]
  );
  const isPending = setRole.isPending || revoke.isPending;
  const canManage = permissions.set_policy && !!vm.instanceIdentityPrincipalId;

  const handleRoleChange = async (role: string) => {
    if (!vm.instanceIdentityPrincipalId || role === grant?.role) return;
    const roleName = roles.find((candidate) => candidate.id === role)?.name ?? role;
    try {
      const result = await setRole.mutateAsync({
        registrationId: vm.instanceIdentityPrincipalId,
        role,
      });
      toast.success(`Assigned the ${roleName} role to ${vm.name}`);
      warnAboutGrantCeilings(result, `${vm.name}'s ${roleName} role`);
    } catch (error) {
      toast.error(
        projectMemberErrorMessage(error, "Failed to update instance access")
      );
    }
  };

  const handleRevoke = async () => {
    if (!vm.instanceIdentityPrincipalId || !grant) return;
    if (!window.confirm(`Revoke ${vm.name}'s ${grant.roleDisplayName} role?`)) {
      return;
    }
    try {
      await revoke.mutateAsync(vm.instanceIdentityPrincipalId);
      toast.success(`Revoked ${vm.name}'s project access`);
    } catch (error) {
      toast.error(
        projectMemberErrorMessage(error, "Failed to revoke instance access")
      );
    }
  };

  const identityState =
    vm.instanceIdentityStatus === "revoked"
      ? "revoked"
      : vm.spiffeId && vm.instanceIdentityPrincipalId
        ? "enabled"
        : "unavailable";
  const identityAvailable = identityState === "enabled";

  return (
    <Card className="bg-card border-border">
      <CardHeader>
        <div className="flex items-start justify-between gap-4">
          <div className="space-y-1">
            <CardTitle className="text-lg font-semibold text-foreground flex items-center gap-2">
              <Fingerprint className="h-5 w-5 text-blue-600" />
              Instance identity
            </CardTitle>
            <p className="text-sm text-muted-foreground">
              Anything running inside this VM can request credentials as this
              principal. Access remains denied until you assign it a role.
            </p>
          </div>
          <Badge
            variant="outline"
            className={
              identityAvailable
                ? "border-green-500/60 bg-green-500/10 text-green-700 dark:text-green-400"
                : identityState === "revoked"
                  ? "border-red-500/60 bg-red-500/10 text-red-700 dark:text-red-400"
                  : "border-border bg-muted text-muted-foreground"
            }
          >
            {identityAvailable ? (
              <ShieldCheck className="h-3.5 w-3.5 mr-1" />
            ) : identityState === "revoked" ? (
              <ShieldOff className="h-3.5 w-3.5 mr-1" />
            ) : (
              <CircleHelp className="h-3.5 w-3.5 mr-1" />
            )}
            {identityAvailable
              ? "Enabled"
              : identityState === "revoked"
                ? "Revoked"
                : "Unavailable"}
          </Badge>
        </div>
      </CardHeader>
      <CardContent className="space-y-5">
        {identityAvailable ? (
          <>
            <div>
              <p className="text-sm text-muted-foreground mb-1">SPIFFE ID</p>
              <div className="flex items-center gap-2 rounded-md border border-border bg-background p-2">
                <code className="min-w-0 flex-1 break-all text-sm text-foreground">
                  {vm.spiffeId}
                </code>
                <CopyButton
                  value={vm.spiffeId!}
                  label="Copy SPIFFE ID"
                  toastMessage="SPIFFE ID copied"
                />
              </div>
            </div>

            {vm.metadataEnabled === false && (
              <p className="rounded-md border border-amber-500/40 bg-amber-500/10 p-3 text-sm text-amber-800 dark:text-amber-300">
                Instance metadata is disabled, so software in this VM cannot
                currently request identity credentials. The principal and its
                role assignment still exist.
              </p>
            )}

            <div className="flex flex-col gap-2 sm:flex-row sm:items-end">
              <div className="flex-1 space-y-1.5">
                <p className="text-sm text-muted-foreground">
                  Role on this project
                </p>
                {canManage ? (
                  <Select
                    value={grant?.role}
                    onValueChange={handleRoleChange}
                    disabled={isPending || rolesLoading || membersLoading}
                  >
                    <SelectTrigger className="bg-background border-border text-foreground">
                      <SelectValue
                        placeholder={
                          membersLoading
                            ? "Loading access..."
                            : grant?.roleDisplayName ?? "No role assigned"
                        }
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
                  <p className="text-sm font-medium text-foreground">
                    No role assigned
                  </p>
                )}
              </div>
              {canManage && grant && (
                <Button
                  type="button"
                  variant="outline"
                  className="border-input text-red-600 hover:bg-red-500/10 hover:text-red-700"
                  onClick={handleRevoke}
                  disabled={isPending}
                >
                  {isPending ? (
                    <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  ) : (
                    <Trash2 className="h-4 w-4 mr-2" />
                  )}
                  Revoke role
                </Button>
              )}
            </div>
          </>
        ) : identityState === "revoked" ? (
          <p className="text-sm text-muted-foreground">
            An administrator revoked this VM&apos;s identity. Revocation is
            permanent for this VM; create a replacement VM if it needs a new
            instance identity.
          </p>
        ) : (
          <p className="text-sm text-muted-foreground">
            This control plane did not report the VM&apos;s instance identity
            status. The identity may still be active; verify it before making
            replacement or access decisions.
          </p>
        )}
      </CardContent>
    </Card>
  );
}
