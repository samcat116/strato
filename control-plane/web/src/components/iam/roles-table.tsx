"use client";

import { useState } from "react";
import { Loader2, Pencil, Trash2, Lock } from "lucide-react";
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
import { useDeleteRole, iamErrorMessage } from "@/lib/hooks";
import { toast } from "sonner";
import type { IAMRole, IAMRoleOwnerType } from "@/types/api";

interface RolesTableProps {
  ownerType: IAMRoleOwnerType;
  ownerId: string;
  roles: IAMRole[];
  isLoading?: boolean;
  canManage: boolean;
  onEdit: (role: IAMRole) => void;
}

export function RolesTable({
  ownerType,
  ownerId,
  roles,
  isLoading,
  canManage,
  onEdit,
}: RolesTableProps) {
  const deleteRole = useDeleteRole(ownerType, ownerId);
  const [pendingId, setPendingId] = useState<string | null>(null);

  const handleDelete = async (role: IAMRole) => {
    if (
      !window.confirm(
        `Delete the role "${role.name}"? This can't be undone. If any principal is still bound to it, the delete will be refused until those bindings are revoked.`
      )
    ) {
      return;
    }

    setPendingId(role.id);
    try {
      await deleteRole.mutateAsync(role.id);
      toast.success(`Deleted ${role.name}`);
    } catch (error) {
      // The backend answers 409 with the count of active bindings; surface it.
      toast.error(iamErrorMessage(error, "Failed to delete role"));
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

  if (roles.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        No custom roles defined yet. The seeded viewer, operator, editor, and
        admin roles are always available to bind.
      </div>
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
          <TableHead className="text-muted-foreground font-medium">
            Actions granted
          </TableHead>
          <TableHead className="text-muted-foreground font-medium text-right">
            Manage
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {roles.map((role) => {
          const isPending = pendingId === role.id;
          return (
            <TableRow
              key={role.id}
              className="border-border hover:bg-accent/60"
            >
              <TableCell className="font-medium text-foreground">
                <span className="flex items-center gap-2">
                  {role.name}
                  {role.managed && (
                    <Badge
                      variant="secondary"
                      className="bg-muted text-muted-foreground gap-1"
                      title="A seeded default role, immutable through the API"
                    >
                      <Lock className="h-3 w-3" />
                      Managed
                    </Badge>
                  )}
                </span>
              </TableCell>
              <TableCell className="text-muted-foreground text-sm max-w-xs truncate">
                {role.description || "—"}
              </TableCell>
              <TableCell className="text-foreground/80 text-sm">
                {role.actions.length}
              </TableCell>
              <TableCell className="text-right">
                <div className="flex items-center justify-end gap-1">
                  {role.managed ? (
                    <Button
                      size="icon-sm"
                      variant="ghost"
                      className="text-muted-foreground hover:text-foreground hover:bg-accent"
                      onClick={() => onEdit(role)}
                      aria-label={`View ${role.name}`}
                      title="View role"
                    >
                      <Pencil className="h-4 w-4" />
                    </Button>
                  ) : (
                    canManage && (
                      <>
                        <Button
                          size="icon-sm"
                          variant="ghost"
                          className="text-muted-foreground hover:text-foreground hover:bg-accent"
                          onClick={() => onEdit(role)}
                          aria-label={`Edit ${role.name}`}
                        >
                          <Pencil className="h-4 w-4" />
                        </Button>
                        <Button
                          size="icon-sm"
                          variant="ghost"
                          className="text-muted-foreground hover:text-red-600 hover:bg-red-500/10"
                          onClick={() => handleDelete(role)}
                          disabled={isPending}
                          aria-label={`Delete ${role.name}`}
                        >
                          {isPending ? (
                            <Loader2 className="h-4 w-4 animate-spin" />
                          ) : (
                            <Trash2 className="h-4 w-4" />
                          )}
                        </Button>
                      </>
                    )
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
