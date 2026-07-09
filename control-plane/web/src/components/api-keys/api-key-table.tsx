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
          <Skeleton key={i} className="h-12 w-full bg-muted" />
        ))}
      </div>
    );
  }

  if (apiKeys.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        No API keys yet. Create one to access the Strato API programmatically.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">Name</TableHead>
          <TableHead className="text-muted-foreground font-medium">Key</TableHead>
          <TableHead className="text-muted-foreground font-medium">Scopes</TableHead>
          <TableHead className="text-muted-foreground font-medium">Status</TableHead>
          <TableHead className="text-muted-foreground font-medium">Created</TableHead>
          <TableHead className="text-muted-foreground font-medium">Expires</TableHead>
          <TableHead className="text-muted-foreground font-medium">Last Used</TableHead>
          <TableHead className="text-muted-foreground font-medium text-right">
            Actions
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {apiKeys.map((key) => {
          const expired = isExpired(key);
          return (
            <TableRow
              key={key.id}
              className="border-border hover:bg-accent/60"
            >
              <TableCell>
                <span className="font-medium text-foreground">{key.name}</span>
              </TableCell>
              <TableCell className="text-foreground/80 font-mono text-sm">
                {key.keyPrefix}
              </TableCell>
              <TableCell>
                <div className="flex flex-wrap gap-1">
                  {key.scopes.map((scope) => (
                    <Badge
                      key={scope}
                      variant="secondary"
                      className="bg-muted text-foreground"
                    >
                      {scope}
                    </Badge>
                  ))}
                </div>
              </TableCell>
              <TableCell>
                {expired ? (
                  <Badge className="bg-yellow-500/10 text-yellow-700 border-transparent">
                    Expired
                  </Badge>
                ) : key.isActive ? (
                  <Badge className="bg-green-500/10 text-green-700 border-transparent">
                    Active
                  </Badge>
                ) : (
                  <Badge className="bg-muted text-foreground/80 border-transparent">
                    Inactive
                  </Badge>
                )}
              </TableCell>
              <TableCell className="text-muted-foreground text-sm">
                {key.createdAt
                  ? new Date(key.createdAt).toLocaleDateString()
                  : "—"}
              </TableCell>
              <TableCell className="text-muted-foreground text-sm">
                {key.expiresAt
                  ? new Date(key.expiresAt).toLocaleDateString()
                  : "Never"}
              </TableCell>
              <TableCell className="text-muted-foreground text-sm">
                {key.lastUsedAt
                  ? new Date(key.lastUsedAt).toLocaleString()
                  : "Never"}
              </TableCell>
              <TableCell className="text-right">
                <Button
                  size="icon-sm"
                  variant="ghost"
                  className="text-muted-foreground hover:text-red-600 hover:bg-red-500/10"
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
