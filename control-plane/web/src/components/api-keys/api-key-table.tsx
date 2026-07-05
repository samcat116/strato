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
import { useRevokeAPIKey } from "@/lib/hooks";
import { toast } from "sonner";
import type { APIKey } from "@/types/api";

interface APIKeyTableProps {
  apiKeys: APIKey[];
  isLoading?: boolean;
}

function isExpired(key: APIKey): boolean {
  return !!key.expiresAt && new Date(key.expiresAt).getTime() < Date.now();
}

export function APIKeyTable({ apiKeys, isLoading }: APIKeyTableProps) {
  const revokeKey = useRevokeAPIKey();
  const [pendingId, setPendingId] = useState<string | null>(null);

  const handleRevoke = async (key: APIKey) => {
    if (
      !window.confirm(
        `Revoke API key "${key.name}"? Any client using it will immediately lose access. This cannot be undone.`
      )
    ) {
      return;
    }

    setPendingId(key.id);
    try {
      await revokeKey.mutateAsync(key.id);
      toast.success(`API key "${key.name}" revoked`);
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to revoke API key"
      );
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

  if (apiKeys.length === 0) {
    return (
      <div className="text-center py-8 text-gray-400">
        No API keys yet. Create one to access the Strato API programmatically.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-gray-900">
        <TableRow className="border-gray-700 hover:bg-gray-900">
          <TableHead className="text-gray-400 font-medium">Name</TableHead>
          <TableHead className="text-gray-400 font-medium">Key</TableHead>
          <TableHead className="text-gray-400 font-medium">Scopes</TableHead>
          <TableHead className="text-gray-400 font-medium">Status</TableHead>
          <TableHead className="text-gray-400 font-medium">Created</TableHead>
          <TableHead className="text-gray-400 font-medium">Expires</TableHead>
          <TableHead className="text-gray-400 font-medium">Last Used</TableHead>
          <TableHead className="text-gray-400 font-medium text-right">
            Actions
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-gray-700">
        {apiKeys.map((key) => {
          const expired = isExpired(key);
          return (
            <TableRow
              key={key.id}
              className="border-gray-700 hover:bg-gray-800/50"
            >
              <TableCell>
                <span className="font-medium text-gray-100">{key.name}</span>
              </TableCell>
              <TableCell className="text-gray-300 font-mono text-sm">
                {key.keyPrefix}
              </TableCell>
              <TableCell>
                <div className="flex flex-wrap gap-1">
                  {key.scopes.map((scope) => (
                    <Badge
                      key={scope}
                      variant="secondary"
                      className="bg-gray-700 text-gray-200"
                    >
                      {scope}
                    </Badge>
                  ))}
                </div>
              </TableCell>
              <TableCell>
                {expired ? (
                  <Badge className="bg-yellow-900/40 text-yellow-300 border-transparent">
                    Expired
                  </Badge>
                ) : key.isActive ? (
                  <Badge className="bg-green-900/40 text-green-300 border-transparent">
                    Active
                  </Badge>
                ) : (
                  <Badge className="bg-gray-700 text-gray-300 border-transparent">
                    Inactive
                  </Badge>
                )}
              </TableCell>
              <TableCell className="text-gray-400 text-sm">
                {key.createdAt
                  ? new Date(key.createdAt).toLocaleDateString()
                  : "—"}
              </TableCell>
              <TableCell className="text-gray-400 text-sm">
                {key.expiresAt
                  ? new Date(key.expiresAt).toLocaleDateString()
                  : "Never"}
              </TableCell>
              <TableCell className="text-gray-400 text-sm">
                {key.lastUsedAt
                  ? new Date(key.lastUsedAt).toLocaleString()
                  : "Never"}
              </TableCell>
              <TableCell className="text-right">
                <Button
                  size="icon-sm"
                  variant="ghost"
                  className="text-gray-400 hover:text-red-400 hover:bg-red-950/30"
                  onClick={() => handleRevoke(key)}
                  disabled={pendingId === key.id}
                  aria-label={`Revoke ${key.name}`}
                >
                  {pendingId === key.id ? (
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
