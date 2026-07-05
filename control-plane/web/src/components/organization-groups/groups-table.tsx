"use client";

import { useState } from "react";
import { Loader2, Pencil, Trash2, Users } from "lucide-react";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { useDeleteGroup, groupErrorMessage } from "@/lib/hooks";
import { toast } from "sonner";
import type { Group } from "@/types/api";

interface GroupsTableProps {
  orgId: string;
  groups: Group[];
  isLoading?: boolean;
  canManage: boolean;
  onEdit: (group: Group) => void;
  onManageMembers: (group: Group) => void;
}

export function GroupsTable({
  orgId,
  groups,
  isLoading,
  canManage,
  onEdit,
  onManageMembers,
}: GroupsTableProps) {
  const deleteGroup = useDeleteGroup(orgId);
  const [pendingId, setPendingId] = useState<string | null>(null);

  const handleDelete = async (group: Group) => {
    if (
      !window.confirm(
        `Delete the group "${group.name}"? Members will be removed from the group but not from the organization.`
      )
    ) {
      return;
    }

    setPendingId(group.id);
    try {
      await deleteGroup.mutateAsync(group.id);
      toast.success(`Deleted ${group.name}`);
    } catch (error) {
      toast.error(groupErrorMessage(error, "Failed to delete group"));
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

  if (groups.length === 0) {
    return (
      <div className="text-center py-8 text-gray-400">No groups yet.</div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-gray-900">
        <TableRow className="border-gray-700 hover:bg-gray-900">
          <TableHead className="text-gray-400 font-medium">Name</TableHead>
          <TableHead className="text-gray-400 font-medium">
            Description
          </TableHead>
          <TableHead className="text-gray-400 font-medium">Members</TableHead>
          <TableHead className="text-gray-400 font-medium text-right">
            Actions
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-gray-700">
        {groups.map((group) => {
          const isPending = pendingId === group.id;
          return (
            <TableRow
              key={group.id}
              className="border-gray-700 hover:bg-gray-800/50"
            >
              <TableCell className="font-medium text-gray-100">
                {group.name}
              </TableCell>
              <TableCell className="text-gray-400 text-sm">
                {group.description || "—"}
              </TableCell>
              <TableCell className="text-gray-300 text-sm">
                {group.memberCount ?? 0}
              </TableCell>
              <TableCell className="text-right">
                <div className="flex items-center justify-end gap-1">
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    className="text-gray-400 hover:text-gray-100 hover:bg-gray-700"
                    onClick={() => onManageMembers(group)}
                    aria-label={`Manage members of ${group.name}`}
                  >
                    <Users className="h-4 w-4" />
                  </Button>
                  {canManage && (
                    <>
                      <Button
                        size="icon-sm"
                        variant="ghost"
                        className="text-gray-400 hover:text-gray-100 hover:bg-gray-700"
                        onClick={() => onEdit(group)}
                        aria-label={`Edit ${group.name}`}
                      >
                        <Pencil className="h-4 w-4" />
                      </Button>
                      <Button
                        size="icon-sm"
                        variant="ghost"
                        className="text-gray-400 hover:text-red-400 hover:bg-red-950/30"
                        onClick={() => handleDelete(group)}
                        disabled={isPending}
                        aria-label={`Delete ${group.name}`}
                      >
                        {isPending ? (
                          <Loader2 className="h-4 w-4 animate-spin" />
                        ) : (
                          <Trash2 className="h-4 w-4" />
                        )}
                      </Button>
                    </>
                  )}
                </div>
              </TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
