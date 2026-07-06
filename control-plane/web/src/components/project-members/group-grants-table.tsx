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
          <Skeleton key={i} className="h-12 w-full bg-gray-700" />
        ))}
      </div>
    );
  }

  if (grants.length === 0) {
    return (
      <div className="text-center py-8 text-gray-400">
        No groups have been granted a role on this project yet.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-gray-900">
        <TableRow className="border-gray-700 hover:bg-gray-900">
          <TableHead className="text-gray-400 font-medium">Group</TableHead>
          <TableHead className="text-gray-400 font-medium">Role</TableHead>
          <TableHead className="text-gray-400 font-medium">Granted</TableHead>
          {canManage && (
            <TableHead className="text-gray-400 font-medium text-right">
              Actions
            </TableHead>
          )}
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-gray-700">
        {grants.map((grant) => {
          const isPending = pendingId === grant.groupId;
          return (
            <TableRow
              key={grant.groupId}
              className="border-gray-700 hover:bg-gray-800/50"
            >
              <TableCell className="font-medium text-gray-100">
                {grant.name}
              </TableCell>
              <TableCell>
                <Badge
                  variant="secondary"
                  className="bg-gray-700 text-gray-200 capitalize"
                >
                  {grant.role}
                </Badge>
              </TableCell>
              <TableCell className="text-gray-400 text-sm">
                {grant.grantedAt
                  ? new Date(grant.grantedAt).toLocaleDateString()
                  : "—"}
              </TableCell>
              {canManage && (
                <TableCell className="text-right">
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    className="text-gray-400 hover:text-red-400 hover:bg-red-950/30"
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
