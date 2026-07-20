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
import { useRevokeCLISession } from "@/lib/hooks";
import { toast } from "sonner";
import type { CLISession } from "@/types/api";

interface CLISessionTableProps {
  sessions: CLISession[];
  isLoading?: boolean;
}

export function CLISessionTable({ sessions, isLoading }: CLISessionTableProps) {
  const revokeSession = useRevokeCLISession();
  const [pendingId, setPendingId] = useState<string | null>(null);

  const handleRevoke = async (session: CLISession) => {
    if (
      !window.confirm(
        `Revoke CLI session "${session.clientName}"? The CLI will be signed out immediately and must log in again.`
      )
    ) {
      return;
    }

    setPendingId(session.id);
    try {
      await revokeSession.mutateAsync(session.id);
      toast.success(`CLI session "${session.clientName}" revoked`);
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to revoke CLI session"
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

  if (sessions.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        No active CLI sessions. Run <code className="font-mono">strato login</code>{" "}
        to sign in from a terminal.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">Device</TableHead>
          <TableHead className="text-muted-foreground font-medium">Token</TableHead>
          <TableHead className="text-muted-foreground font-medium">Scopes</TableHead>
          <TableHead className="text-muted-foreground font-medium">Signed In</TableHead>
          <TableHead className="text-muted-foreground font-medium">Last Used</TableHead>
          <TableHead className="text-muted-foreground font-medium">Expires</TableHead>
          <TableHead className="text-muted-foreground font-medium text-right">
            Actions
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {sessions.map((session) => (
          <TableRow key={session.id} className="border-border hover:bg-accent/60">
            <TableCell>
              <span className="font-medium text-foreground">
                {session.clientName}
              </span>
              {session.lastUsedIP && (
                <span className="block text-xs text-muted-foreground">
                  {session.lastUsedIP}
                </span>
              )}
            </TableCell>
            <TableCell className="text-foreground/80 font-mono text-sm">
              {session.accessTokenPrefix}
            </TableCell>
            <TableCell>
              <div className="flex flex-wrap gap-1">
                {session.scopes.map((scope) => (
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
            <TableCell className="text-muted-foreground text-sm">
              {session.createdAt
                ? new Date(session.createdAt).toLocaleString()
                : "—"}
            </TableCell>
            <TableCell className="text-muted-foreground text-sm">
              {session.lastUsedAt
                ? new Date(session.lastUsedAt).toLocaleString()
                : "Never"}
            </TableCell>
            <TableCell className="text-muted-foreground text-sm">
              {new Date(session.refreshTokenExpiresAt).toLocaleDateString()}
            </TableCell>
            <TableCell className="text-right">
              <Button
                size="icon-sm"
                variant="ghost"
                className="text-muted-foreground hover:text-red-600 hover:bg-red-500/10"
                onClick={() => handleRevoke(session)}
                disabled={pendingId === session.id}
                aria-label={`Revoke ${session.clientName}`}
              >
                {pendingId === session.id ? (
                  <Loader2 className="h-4 w-4 animate-spin" />
                ) : (
                  <Trash2 className="h-4 w-4" />
                )}
              </Button>
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
