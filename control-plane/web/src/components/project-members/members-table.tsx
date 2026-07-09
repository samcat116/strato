"use client";

import { useState } from "react";
import { Loader2, Trash2 } from "lucide-react";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  useRevokeProjectMember,
  useUpdateProjectMemberRole,
  projectMemberErrorMessage,
} from "@/lib/hooks";
import { toast } from "sonner";
import type { ProjectMember, ProjectRole } from "@/types/api";

const ROLES: ProjectRole[] = ["admin", "member", "viewer"];

interface MembersTableProps {
  projectId: string;
  members: ProjectMember[];
  isLoading?: boolean;
  canManage: boolean;
}

export function MembersTable({
  projectId,
  members,
  isLoading,
  canManage,
}: MembersTableProps) {
  const revoke = useRevokeProjectMember(projectId);
  const updateRole = useUpdateProjectMemberRole(projectId);
  const [pendingId, setPendingId] = useState<string | null>(null);

  const handleRevoke = async (member: ProjectMember) => {
    if (
      !window.confirm(
        `Remove ${member.displayName || member.username} from this project?`
      )
    ) {
      return;
    }
    setPendingId(member.userId);
    try {
      await revoke.mutateAsync(member.userId);
      toast.success(`Removed ${member.displayName || member.username}`);
    } catch (error) {
      toast.error(projectMemberErrorMessage(error, "Failed to remove member"));
    } finally {
      setPendingId(null);
    }
  };

  const handleRoleChange = async (member: ProjectMember, role: ProjectRole) => {
    if (role === member.role) return;
    setPendingId(member.userId);
    try {
      await updateRole.mutateAsync({ userId: member.userId, role });
      toast.success(`Updated ${member.displayName || member.username} to ${role}`);
    } catch (error) {
      toast.error(projectMemberErrorMessage(error, "Failed to update role"));
    } finally {
      setPendingId(null);
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

  if (members.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        No members have a direct role on this project yet.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">User</TableHead>
          <TableHead className="text-muted-foreground font-medium">Role</TableHead>
          <TableHead className="text-muted-foreground font-medium">Added</TableHead>
          {canManage && (
            <TableHead className="text-muted-foreground font-medium text-right">
              Actions
            </TableHead>
          )}
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {members.map((member) => {
          const isPending = pendingId === member.userId;
          return (
            <TableRow
              key={member.userId}
              className="border-border hover:bg-accent/60"
            >
              <TableCell>
                <div className="flex flex-col">
                  <span className="font-medium text-foreground">
                    {member.displayName || member.username}
                  </span>
                  <span className="text-sm text-muted-foreground">{member.email}</span>
                </div>
              </TableCell>
              <TableCell>
                {canManage ? (
                  <Select
                    value={member.role}
                    onValueChange={(role) =>
                      handleRoleChange(member, role as ProjectRole)
                    }
                    disabled={isPending}
                  >
                    <SelectTrigger className="w-32 bg-background border-border text-foreground capitalize">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent className="bg-card border-border">
                      {ROLES.map((role) => (
                        <SelectItem
                          key={role}
                          value={role}
                          className="text-foreground capitalize focus:bg-accent focus:text-accent-foreground"
                        >
                          {role}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                ) : (
                  <Badge
                    variant="secondary"
                    className="bg-muted text-foreground capitalize"
                  >
                    {member.role}
                  </Badge>
                )}
              </TableCell>
              <TableCell className="text-muted-foreground text-sm">
                {member.joinedAt
                  ? new Date(member.joinedAt).toLocaleDateString()
                  : "—"}
              </TableCell>
              {canManage && (
                <TableCell className="text-right">
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    className="text-muted-foreground hover:text-red-600 hover:bg-red-500/10"
                    onClick={() => handleRevoke(member)}
                    disabled={isPending}
                    aria-label={`Remove ${member.displayName || member.username}`}
                  >
                    {isPending ? (
                      <Loader2 className="h-4 w-4 animate-spin" />
                    ) : (
                      <Trash2 className="h-4 w-4" />
                    )}
                  </Button>
                </TableCell>
              )}
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
