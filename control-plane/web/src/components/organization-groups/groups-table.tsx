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
          <Skeleton key={i} className="h-12 w-full bg-muted" />
        ))}
      </div>
    );
  }

  if (groups.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">No groups yet.</div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">Name</TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Description
          </TableHead>
          <TableHead className="text-muted-foreground font-medium">Members</TableHead>
          <TableHead className="text-muted-foreground font-medium text-right">
            Actions
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {groups.map((group) => {
          const isPending = pendingId === group.id;
          return (
            <TableRow
              key={group.id}
              className="border-border hover:bg-accent/60"
            >
              <TableCell className="font-medium text-foreground">
                {group.name}
              </TableCell>
              <TableCell className="text-muted-foreground text-sm">
                {group.description || "—"}
              </TableCell>
              <TableCell className="text-foreground/80 text-sm">
                {group.memberCount ?? 0}
              </TableCell>
              <TableCell className="text-right">
                <div className="flex items-center justify-end gap-1">
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    className="text-muted-foreground hover:text-foreground hover:bg-accent"
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
                        className="text-muted-foreground hover:text-foreground hover:bg-accent"
                        onClick={() => onEdit(group)}
                        aria-label={`Edit ${group.name}`}
                      >
                        <Pencil className="h-4 w-4" />
                      </Button>
                      <Button
                        size="icon-sm"
                        variant="ghost"
                        className="text-muted-foreground hover:text-red-600 hover:bg-red-500/10"
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
