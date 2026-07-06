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
          <Skeleton key={i} className="h-12 w-full bg-gray-700" />
        ))}
      </div>
    );
  }

  if (members.length === 0) {
    return (
      <div className="text-center py-8 text-gray-400">
        No members have a direct role on this project yet.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-gray-900">
        <TableRow className="border-gray-700 hover:bg-gray-900">
          <TableHead className="text-gray-400 font-medium">User</TableHead>
          <TableHead className="text-gray-400 font-medium">Role</TableHead>
          <TableHead className="text-gray-400 font-medium">Added</TableHead>
          {canManage && (
            <TableHead className="text-gray-400 font-medium text-right">
              Actions
            </TableHead>
          )}
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-gray-700">
        {members.map((member) => {
          const isPending = pendingId === member.userId;
          return (
            <TableRow
              key={member.userId}
              className="border-gray-700 hover:bg-gray-800/50"
            >
              <TableCell>
                <div className="flex flex-col">
                  <span className="font-medium text-gray-100">
                    {member.displayName || member.username}
                  </span>
                  <span className="text-sm text-gray-400">{member.email}</span>
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
                    <SelectTrigger className="w-32 bg-gray-900 border-gray-700 text-gray-100 capitalize">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent className="bg-gray-800 border-gray-700">
                      {ROLES.map((role) => (
                        <SelectItem
                          key={role}
                          value={role}
                          className="text-gray-100 capitalize focus:bg-gray-700 focus:text-gray-100"
                        >
                          {role}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                ) : (
                  <Badge
                    variant="secondary"
                    className="bg-gray-700 text-gray-200 capitalize"
                  >
                    {member.role}
                  </Badge>
                )}
              </TableCell>
              <TableCell className="text-gray-400 text-sm">
                {member.joinedAt
                  ? new Date(member.joinedAt).toLocaleDateString()
                  : "—"}
              </TableCell>
              {canManage && (
                <TableCell className="text-right">
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    className="text-gray-400 hover:text-red-400 hover:bg-red-950/30"
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
