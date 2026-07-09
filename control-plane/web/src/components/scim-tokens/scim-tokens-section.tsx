"use client";

import { useState } from "react";
import { Loader2, Plus, Trash2, Power } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { CreateSCIMTokenDialog } from "./create-scim-token-dialog";
import {
  useSCIMTokens,
  useUpdateSCIMToken,
  useDeleteSCIMToken,
  scimTokenErrorMessage,
} from "@/lib/hooks/use-scim-tokens";
import { toast } from "sonner";
import type { SCIMToken } from "@/types/api";

interface SCIMTokensSectionProps {
  orgId: string;
  canManage: boolean;
}

function isExpired(token: SCIMToken): boolean {
  return !!token.expiresAt && new Date(token.expiresAt).getTime() < Date.now();
}

export function SCIMTokensSection({ orgId, canManage }: SCIMTokensSectionProps) {
  const [createOpen, setCreateOpen] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<SCIMToken | null>(null);
  const { data: tokens = [], isLoading } = useSCIMTokens(orgId, canManage);
  const updateToken = useUpdateSCIMToken(orgId);
  const deleteToken = useDeleteSCIMToken(orgId);
  const [togglePendingId, setTogglePendingId] = useState<string | null>(null);

  const handleToggleActive = async (token: SCIMToken) => {
    setTogglePendingId(token.id);
    try {
      await updateToken.mutateAsync({
        tokenId: token.id,
        data: { isActive: !token.isActive },
      });
      toast.success(
        `Token "${token.name}" ${token.isActive ? "deactivated" : "activated"}`
      );
    } catch (error) {
      toast.error(scimTokenErrorMessage(error, "Failed to update token"));
    } finally {
      setTogglePendingId(null);
    }
  };

  const handleDelete = async () => {
    if (!deleteTarget) return;
    try {
      await deleteToken.mutateAsync(deleteTarget.id);
      toast.success(`Token "${deleteTarget.name}" deleted`);
      setDeleteTarget(null);
    } catch (error) {
      toast.error(scimTokenErrorMessage(error, "Failed to delete token"));
    }
  };

  return (
    <Card className="bg-card border-border">
      <CardHeader className="flex flex-row items-center justify-between space-y-0">
        <CardTitle className="text-lg font-semibold text-foreground">
          SCIM Provisioning Tokens
        </CardTitle>
        {canManage && (
          <Button
            size="sm"
            className="bg-primary hover:bg-primary/90"
            onClick={() => setCreateOpen(true)}
          >
            <Plus className="h-4 w-4 mr-2" />
            Create Token
          </Button>
        )}
      </CardHeader>
      <CardContent>
        <p className="text-sm text-muted-foreground mb-4">
          Bearer tokens that let your identity provider (Okta, Entra ID, ...)
          provision and deprovision users in this organization via SCIM.
        </p>

        {!canManage ? (
          <p className="text-sm text-muted-foreground">
            You need admin rights to manage SCIM tokens.
          </p>
        ) : isLoading ? (
          <div className="space-y-2">
            {[...Array(2)].map((_, i) => (
              <Skeleton key={i} className="h-12 w-full bg-muted" />
            ))}
          </div>
        ) : tokens.length === 0 ? (
          <div className="text-center py-8 text-muted-foreground">
            No SCIM tokens yet. Create one to connect your identity provider.
          </div>
        ) : (
          <Table>
            <TableHeader className="bg-background">
              <TableRow className="border-border hover:bg-transparent">
                <TableHead className="text-muted-foreground font-medium">
                  Name
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Token
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Status
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Expires
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Last Used
                </TableHead>
                <TableHead className="text-muted-foreground font-medium text-right">
                  Actions
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody className="divide-y divide-border">
              {tokens.map((token) => {
                const expired = isExpired(token);
                return (
                  <TableRow
                    key={token.id}
                    className="border-border hover:bg-accent/60"
                  >
                    <TableCell>
                      <span className="font-medium text-foreground">
                        {token.name}
                      </span>
                    </TableCell>
                    <TableCell className="text-foreground/80 font-mono text-sm">
                      {token.tokenPrefix}…
                    </TableCell>
                    <TableCell>
                      {expired ? (
                        <Badge className="bg-yellow-500/10 text-yellow-700 border-transparent">
                          Expired
                        </Badge>
                      ) : token.isActive ? (
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
                      {token.expiresAt
                        ? new Date(token.expiresAt).toLocaleDateString()
                        : "Never"}
                    </TableCell>
                    <TableCell className="text-muted-foreground text-sm">
                      {token.lastUsedAt
                        ? new Date(token.lastUsedAt).toLocaleString()
                        : "Never"}
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex items-center justify-end gap-1">
                        <Button
                          size="icon-sm"
                          variant="ghost"
                          className="text-muted-foreground hover:text-foreground"
                          onClick={() => handleToggleActive(token)}
                          disabled={togglePendingId === token.id}
                          aria-label={
                            token.isActive
                              ? `Deactivate ${token.name}`
                              : `Activate ${token.name}`
                          }
                          title={token.isActive ? "Deactivate" : "Activate"}
                        >
                          {togglePendingId === token.id ? (
                            <Loader2 className="h-4 w-4 animate-spin" />
                          ) : (
                            <Power className="h-4 w-4" />
                          )}
                        </Button>
                        <Button
                          size="icon-sm"
                          variant="ghost"
                          className="text-muted-foreground hover:text-red-600 hover:bg-red-500/10"
                          onClick={() => setDeleteTarget(token)}
                          aria-label={`Delete ${token.name}`}
                        >
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        )}
      </CardContent>

      {canManage && (
        <CreateSCIMTokenDialog
          orgId={orgId}
          open={createOpen}
          onOpenChange={setCreateOpen}
        />
      )}

      {/* Delete confirmation dialog */}
      <Dialog
        open={!!deleteTarget}
        onOpenChange={(open) => {
          if (!open) setDeleteTarget(null);
        }}
      >
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Delete {deleteTarget?.name}?</DialogTitle>
            <DialogDescription className="text-muted-foreground">
              Your identity provider will immediately lose access and SCIM
              provisioning will stop working until you configure a new token.
              This cannot be undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              className="border-input"
              onClick={() => setDeleteTarget(null)}
              disabled={deleteToken.isPending}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={handleDelete}
              disabled={deleteToken.isPending}
            >
              {deleteToken.isPending ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Trash2 className="h-4 w-4" />
              )}
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </Card>
  );
}
