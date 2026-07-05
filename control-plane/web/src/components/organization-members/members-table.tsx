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
  useRemoveMember,
  useUpdateMemberRole,
  memberErrorMessage,
} from "@/lib/hooks";
import { toast } from "sonner";
import type { OrganizationMember } from "@/types/api";

interface MembersTableProps {
  orgId: string;
  members: OrganizationMember[];
  isLoading?: boolean;
  /** Whether the current user can manage members (org admin). */
  canManage: boolean;
  /** Current user's ID, used to highlight their own row. */
  currentUserId?: string;
}

export function MembersTable({
  orgId,
  members,
  isLoading,
  canManage,
  currentUserId,
}: MembersTableProps) {
  const removeMember = useRemoveMember(orgId);
  const updateRole = useUpdateMemberRole(orgId);
  const [pendingId, setPendingId] = useState<string | null>(null);

  const handleRemove = async (member: OrganizationMember) => {
    if (
      !window.confirm(
        `Remove ${member.displayName || member.username} from this organization? They will lose access to its projects and resources.`
      )
    ) {
      return;
    }

    setPendingId(member.id);
    try {
      await removeMember.mutateAsync(member.id);
      toast.success(`Removed ${member.displayName || member.username}`);
    } catch (error) {
      toast.error(memberErrorMessage(error, "Failed to remove member"));
    } finally {
      setPendingId(null);
    }
  };

  const handleRoleChange = async (
    member: OrganizationMember,
    role: string
  ) => {
    if (role === member.role) return;

    setPendingId(member.id);
    try {
      await updateRole.mutateAsync({ userId: member.id, role });
      toast.success(
        `Updated ${member.displayName || member.username} to ${role}`
      );
    } catch (error) {
      toast.error(memberErrorMessage(error, "Failed to update member role"));
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
        No members yet.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-gray-900">
        <TableRow className="border-gray-700 hover:bg-gray-900">
          <TableHead className="text-gray-400 font-medium">User</TableHead>
          <TableHead className="text-gray-400 font-medium">Role</TableHead>
          <TableHead className="text-gray-400 font-medium">Joined</TableHead>
          {canManage && (
            <TableHead className="text-gray-400 font-medium text-right">
              Actions
            </TableHead>
          )}
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-gray-700">
        {members.map((member) => {
          const isSelf = member.id === currentUserId;
          const isPending = pendingId === member.id;
          return (
            <TableRow
              key={member.id}
              className="border-gray-700 hover:bg-gray-800/50"
            >
              <TableCell>
                <div className="flex flex-col">
                  <span className="font-medium text-gray-100">
                    {member.displayName || member.username}
                    {isSelf && (
                      <span className="ml-2 text-xs text-gray-500">(you)</span>
                    )}
                  </span>
                  <span className="text-sm text-gray-400">{member.email}</span>
                </div>
              </TableCell>
              <TableCell>
                {canManage ? (
                  <Select
                    value={member.role}
                    onValueChange={(role) => handleRoleChange(member, role)}
                    disabled={isPending}
                  >
                    <SelectTrigger className="w-32 bg-gray-900 border-gray-700 text-gray-100">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent className="bg-gray-800 border-gray-700">
                      <SelectItem
                        value="member"
                        className="text-gray-100 focus:bg-gray-700 focus:text-gray-100"
                      >
                        Member
                      </SelectItem>
                      <SelectItem
                        value="admin"
                        className="text-gray-100 focus:bg-gray-700 focus:text-gray-100"
                      >
                        Admin
                      </SelectItem>
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
                    onClick={() => handleRemove(member)}
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
