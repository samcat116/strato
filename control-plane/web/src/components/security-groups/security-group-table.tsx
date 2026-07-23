"use client";

import { useState } from "react";
import { ListChecks, Loader2, Pencil, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Skeleton } from "@/components/ui/skeleton";
import { securityGroupsApi } from "@/lib/api/security-groups";
import { toast } from "sonner";
import type { SecurityGroup } from "@/types/api";

interface SecurityGroupTableProps {
  groups: SecurityGroup[];
  isLoading?: boolean;
  onRefresh?: () => void;
  onEdit?: (group: SecurityGroup) => void;
  onManageRules?: (group: SecurityGroup) => void;
}

export function SecurityGroupTable({
  groups,
  isLoading,
  onRefresh,
  onEdit,
  onManageRules,
}: SecurityGroupTableProps) {
  const [busyId, setBusyId] = useState<string | null>(null);

  const handleDelete = async (group: SecurityGroup) => {
    if (
      !confirm(`Delete security group "${group.name}"? This cannot be undone.`)
    ) {
      return;
    }
    setBusyId(group.id);
    try {
      await securityGroupsApi.delete(group.id);
      toast.success(`Deleted security group "${group.name}"`);
      onRefresh?.();
    } catch (error) {
      toast.error(
        error instanceof Error
          ? error.message
          : "Failed to delete security group"
      );
    } finally {
      setBusyId(null);
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
      <div className="text-center py-8 text-muted-foreground">
        No security groups found. Create one to get started.
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
          <TableHead className="text-muted-foreground font-medium">Rules</TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Attachments
          </TableHead>
          <TableHead className="text-muted-foreground font-medium text-right">
            Actions
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {groups.map((group) => {
          const inUse = group.attachmentCount > 0;
          const deletable = !group.isDefault && !inUse;
          const disabledReason = group.isDefault
            ? "The default security group cannot be deleted"
            : inUse
              ? "Detach all interfaces before deleting"
              : undefined;
          return (
            <TableRow key={group.id} className="border-border hover:bg-accent/60">
              <TableCell>
                <span className="font-medium text-foreground">{group.name}</span>
                {group.isDefault && (
                  <Badge
                    variant="outline"
                    className="ml-2 border-input text-muted-foreground"
                  >
                    default
                  </Badge>
                )}
              </TableCell>
              <TableCell className="text-foreground/80">
                {group.description || "—"}
              </TableCell>
              <TableCell className="text-foreground/80">
                {group.rules.length}
              </TableCell>
              <TableCell className="text-foreground/80">
                {group.attachmentCount}
              </TableCell>
              <TableCell className="text-right">
                <Button
                  size="sm"
                  variant="ghost"
                  className="text-foreground/80 hover:text-foreground hover:bg-accent"
                  onClick={() => onManageRules?.(group)}
                  disabled={busyId === group.id}
                  title="Manage rules"
                >
                  <ListChecks className="h-4 w-4" />
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  className="text-foreground/80 hover:text-foreground hover:bg-accent"
                  onClick={() => onEdit?.(group)}
                  disabled={busyId === group.id}
                  title="Edit name and description"
                >
                  <Pencil className="h-4 w-4" />
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  className="text-red-600 hover:text-red-700 hover:bg-red-500/10"
                  onClick={() => handleDelete(group)}
                  disabled={!deletable || busyId === group.id}
                  title={disabledReason ?? "Delete security group"}
                  aria-label="Delete security group"
                >
                  {busyId === group.id ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <Trash2 className="h-4 w-4" />
                  )}
                </Button>
              </TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
