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
  useRevokeProjectGroup,
  projectMemberErrorMessage,
} from "@/lib/hooks";
import { toast } from "sonner";
import type { ProjectGroupGrant } from "@/types/api";

interface GroupGrantsTableProps {
  projectId: string;
  grants: ProjectGroupGrant[];
  isLoading?: boolean;
  canManage: boolean;
}

export function GroupGrantsTable({
  projectId,
  grants,
  isLoading,
  canManage,
}: GroupGrantsTableProps) {
  const revoke = useRevokeProjectGroup(projectId);
  const [pendingId, setPendingId] = useState<string | null>(null);

  const handleRevoke = async (grant: ProjectGroupGrant) => {
    if (!window.confirm(`Revoke ${grant.name}'s access to this project?`)) {
      return;
    }
    setPendingId(grant.groupId);
    try {
      await revoke.mutateAsync(grant.groupId);
      toast.success(`Revoked ${grant.name}`);
    } catch (error) {
      toast.error(projectMemberErrorMessage(error, "Failed to revoke group"));
    } finally {
      setPendingId(null);
    }
  };

  if (isLoading) {
    return (
      <div className="space-y-2">
        {[...Array(2)].map((_, i) => (
          <Skeleton key={i} className="h-12 w-full bg-muted" />
        ))}
      </div>
    );
  }

  if (grants.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        No groups have been granted a role on this project yet.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">Group</TableHead>
          <TableHead className="text-muted-foreground font-medium">Role</TableHead>
          <TableHead className="text-muted-foreground font-medium">Granted</TableHead>
          {canManage && (
            <TableHead className="text-muted-foreground font-medium text-right">
              Actions
            </TableHead>
          )}
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {grants.map((grant) => {
          const isPending = pendingId === grant.groupId;
          return (
            <TableRow
              key={grant.groupId}
              className="border-border hover:bg-accent/60"
            >
              <TableCell className="font-medium text-foreground">
                <span className="flex items-center gap-2">
                  {grant.name}
                  {grant.external && (
                    <Badge
                      variant="outline"
                      className="border-amber-500/60 bg-amber-500/10 text-amber-600 dark:text-amber-400"
                      title="This group belongs to another organization"
                    >
                      External
                    </Badge>
                  )}
                </span>
              </TableCell>
              <TableCell>
                <Badge
                  variant="secondary"
                  className="bg-muted text-foreground capitalize"
                >
                  {grant.role}
                </Badge>
              </TableCell>
              <TableCell className="text-muted-foreground text-sm">
                {grant.grantedAt
                  ? new Date(grant.grantedAt).toLocaleDateString()
                  : "—"}
              </TableCell>
              {canManage && (
                <TableCell className="text-right">
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    className="text-muted-foreground hover:text-red-600 hover:bg-red-500/10"
                    onClick={() => handleRevoke(grant)}
                    disabled={isPending}
                    aria-label={`Revoke ${grant.name}`}
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
