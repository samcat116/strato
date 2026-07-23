"use client";

import { useState } from "react";
import { Loader2, Pencil, Trash2 } from "lucide-react";
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
  useDeletePolicy,
  useUpdatePolicy,
  iamErrorMessage,
} from "@/lib/hooks";
import { toast } from "sonner";
import type { IAMPolicy, IAMRoleOwnerType } from "@/types/api";

interface PoliciesTableProps {
  ownerType: IAMRoleOwnerType;
  ownerId: string;
  policies: IAMPolicy[];
  isLoading?: boolean;
  canManage: boolean;
  onEdit: (policy: IAMPolicy) => void;
}

export function PoliciesTable({
  ownerType,
  ownerId,
  policies,
  isLoading,
  canManage,
  onEdit,
}: PoliciesTableProps) {
  const deletePolicy = useDeletePolicy(ownerType, ownerId);
  const updatePolicy = useUpdatePolicy(ownerType, ownerId);
  const [pendingId, setPendingId] = useState<string | null>(null);

  const handleDelete = async (policy: IAMPolicy) => {
    if (
      !window.confirm(
        `Delete the policy "${policy.name}"? This can't be undone.`
      )
    ) {
      return;
    }
    setPendingId(policy.id);
    try {
      await deletePolicy.mutateAsync(policy.id);
      toast.success(`Deleted ${policy.name}`);
    } catch (error) {
      toast.error(iamErrorMessage(error, "Failed to delete policy"));
    } finally {
      setPendingId(null);
    }
  };

  const handleToggleEnabled = async (policy: IAMPolicy, enabled: boolean) => {
    setPendingId(policy.id);
    try {
      await updatePolicy.mutateAsync({
        policyId: policy.id,
        data: { enabled },
      });
      toast.success(
        `${enabled ? "Enabled" : "Disabled"} ${policy.name}`
      );
    } catch (error) {
      toast.error(iamErrorMessage(error, "Failed to update policy"));
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

  if (policies.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        No authored policies yet.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">Name</TableHead>
          <TableHead className="text-muted-foreground font-medium">Effect</TableHead>
          <TableHead className="text-muted-foreground font-medium">Enabled</TableHead>
          <TableHead className="text-muted-foreground font-medium text-right">
            Manage
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {policies.map((policy) => {
          const isPending = pendingId === policy.id;
          return (
            <TableRow
              key={policy.id}
              className="border-border hover:bg-accent/60"
            >
              <TableCell className="font-medium text-foreground">
                <div className="flex flex-col">
                  <span>{policy.name}</span>
                  {policy.description && (
                    <span className="text-xs text-muted-foreground">
                      {policy.description}
                    </span>
                  )}
                </div>
              </TableCell>
              <TableCell>
                {policy.effect === "forbid" ? (
                  <Badge
                    variant="outline"
                    className="border-red-500/60 bg-red-500/10 text-red-600 dark:text-red-400"
                  >
                    Forbid
                  </Badge>
                ) : (
                  <Badge
                    variant="outline"
                    className="border-green-500/60 bg-green-500/10 text-green-600 dark:text-green-400"
                  >
                    Permit
                  </Badge>
                )}
              </TableCell>
              <TableCell>
                <label className="flex items-center gap-2 text-sm text-foreground">
                  <input
                    type="checkbox"
                    checked={policy.enabled}
                    onChange={(e) =>
                      handleToggleEnabled(policy, e.target.checked)
                    }
                    disabled={!canManage || isPending}
                    className="h-4 w-4 rounded border-input bg-background accent-blue-600 disabled:opacity-50"
                  />
                  {policy.enabled ? "On" : "Off"}
                </label>
              </TableCell>
              <TableCell className="text-right">
                <div className="flex items-center justify-end gap-1">
                  {canManage && (
                    <>
                      <Button
                        size="icon-sm"
                        variant="ghost"
                        className="text-muted-foreground hover:text-foreground hover:bg-accent"
                        onClick={() => onEdit(policy)}
                        aria-label={`Edit ${policy.name}`}
                      >
                        <Pencil className="h-4 w-4" />
                      </Button>
                      <Button
                        size="icon-sm"
                        variant="ghost"
                        className="text-muted-foreground hover:text-red-600 hover:bg-red-500/10"
                        onClick={() => handleDelete(policy)}
                        disabled={isPending}
                        aria-label={`Delete ${policy.name}`}
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
