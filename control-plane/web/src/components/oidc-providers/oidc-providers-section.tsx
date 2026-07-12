"use client";

import { useState } from "react";
import { FlaskConical, Loader2, Pencil, Plus, Power, Trash2 } from "lucide-react";
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
import { OIDCProviderDialog } from "./oidc-provider-dialog";
import {
  useOIDCProviders,
  useUpdateOIDCProvider,
  useDeleteOIDCProvider,
  useTestOIDCProvider,
  oidcProviderErrorMessage,
} from "@/lib/hooks/use-oidc-providers";
import { toast } from "sonner";
import type { OIDCProvider } from "@/types/api";

interface OIDCProvidersSectionProps {
  orgId: string;
  canManage: boolean;
}

export function OIDCProvidersSection({
  orgId,
  canManage,
}: OIDCProvidersSectionProps) {
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editTarget, setEditTarget] = useState<OIDCProvider | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<OIDCProvider | null>(null);
  const { data: providers = [], isLoading } = useOIDCProviders(orgId);
  const updateProvider = useUpdateOIDCProvider(orgId);
  const deleteProvider = useDeleteOIDCProvider(orgId);
  const testProvider = useTestOIDCProvider(orgId);
  const [togglePendingId, setTogglePendingId] = useState<string | null>(null);
  const [testPendingId, setTestPendingId] = useState<string | null>(null);

  const handleToggleEnabled = async (provider: OIDCProvider) => {
    setTogglePendingId(provider.id);
    try {
      await updateProvider.mutateAsync({
        providerId: provider.id,
        data: { enabled: !provider.enabled },
      });
      toast.success(
        `Provider "${provider.name}" ${provider.enabled ? "disabled" : "enabled"}`
      );
    } catch (error) {
      toast.error(oidcProviderErrorMessage(error, "Failed to update provider"));
    } finally {
      setTogglePendingId(null);
    }
  };

  const handleTest = async (provider: OIDCProvider) => {
    setTestPendingId(provider.id);
    try {
      const result = await testProvider.mutateAsync(provider.id);
      if (result.valid) {
        toast.success(result.message);
      } else {
        toast.error(result.message);
      }
    } catch (error) {
      toast.error(
        oidcProviderErrorMessage(error, "Failed to test provider configuration")
      );
    } finally {
      setTestPendingId(null);
    }
  };

  const handleDelete = async () => {
    if (!deleteTarget) return;
    try {
      await deleteProvider.mutateAsync(deleteTarget.id);
      toast.success(`Provider "${deleteTarget.name}" deleted`);
      setDeleteTarget(null);
    } catch (error) {
      toast.error(oidcProviderErrorMessage(error, "Failed to delete provider"));
    }
  };

  const openCreate = () => {
    setEditTarget(null);
    setDialogOpen(true);
  };

  const openEdit = (provider: OIDCProvider) => {
    setEditTarget(provider);
    setDialogOpen(true);
  };

  return (
    <Card className="bg-card border-border">
      <CardHeader className="flex flex-row items-center justify-between space-y-0">
        <CardTitle className="text-lg font-semibold text-foreground">
          SSO Providers (OIDC)
        </CardTitle>
        {canManage && (
          <Button
            size="sm"
            className="bg-primary hover:bg-primary/90"
            onClick={openCreate}
          >
            <Plus className="h-4 w-4 mr-2" />
            Add Provider
          </Button>
        )}
      </CardHeader>
      <CardContent>
        <p className="text-sm text-muted-foreground mb-4">
          OpenID Connect identity providers members of this organization can
          use to sign in. Enabled providers appear on the login screen when a
          user chooses “Sign in with SSO” and enters this organization&apos;s
          name.
        </p>

        {isLoading ? (
          <div className="space-y-2">
            {[...Array(2)].map((_, i) => (
              <Skeleton key={i} className="h-12 w-full bg-muted" />
            ))}
          </div>
        ) : providers.length === 0 ? (
          <div className="text-center py-8 text-muted-foreground">
            No SSO providers configured.
            {canManage && " Add one to let members sign in with your identity provider."}
          </div>
        ) : (
          <Table>
            <TableHeader className="bg-background">
              <TableRow className="border-border hover:bg-transparent">
                <TableHead className="text-muted-foreground font-medium">
                  Name
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Client ID
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Configuration
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Status
                </TableHead>
                {canManage && (
                  <TableHead className="text-muted-foreground font-medium text-right">
                    Actions
                  </TableHead>
                )}
              </TableRow>
            </TableHeader>
            <TableBody className="divide-y divide-border">
              {providers.map((provider) => (
                <TableRow
                  key={provider.id}
                  className="border-border hover:bg-accent/60"
                >
                  <TableCell>
                    <span className="font-medium text-foreground">
                      {provider.name}
                    </span>
                  </TableCell>
                  <TableCell className="text-foreground/80 font-mono text-sm max-w-48 truncate">
                    {provider.clientID}
                  </TableCell>
                  <TableCell>
                    {provider.discoveryURL ? (
                      <Badge className="bg-blue-500/10 text-blue-700 border-transparent">
                        Discovery
                      </Badge>
                    ) : (
                      <Badge className="bg-muted text-foreground/80 border-transparent">
                        Manual endpoints
                      </Badge>
                    )}
                  </TableCell>
                  <TableCell>
                    {provider.enabled ? (
                      <Badge className="bg-green-500/10 text-green-700 border-transparent">
                        Enabled
                      </Badge>
                    ) : (
                      <Badge className="bg-muted text-foreground/80 border-transparent">
                        Disabled
                      </Badge>
                    )}
                  </TableCell>
                  {canManage && (
                    <TableCell className="text-right">
                      <div className="flex items-center justify-end gap-1">
                        <Button
                          size="icon-sm"
                          variant="ghost"
                          className="text-muted-foreground hover:text-foreground"
                          onClick={() => handleTest(provider)}
                          disabled={testPendingId === provider.id}
                          aria-label={`Test ${provider.name} configuration`}
                          title="Test configuration"
                        >
                          {testPendingId === provider.id ? (
                            <Loader2 className="h-4 w-4 animate-spin" />
                          ) : (
                            <FlaskConical className="h-4 w-4" />
                          )}
                        </Button>
                        <Button
                          size="icon-sm"
                          variant="ghost"
                          className="text-muted-foreground hover:text-foreground"
                          onClick={() => handleToggleEnabled(provider)}
                          disabled={togglePendingId === provider.id}
                          aria-label={
                            provider.enabled
                              ? `Disable ${provider.name}`
                              : `Enable ${provider.name}`
                          }
                          title={provider.enabled ? "Disable" : "Enable"}
                        >
                          {togglePendingId === provider.id ? (
                            <Loader2 className="h-4 w-4 animate-spin" />
                          ) : (
                            <Power className="h-4 w-4" />
                          )}
                        </Button>
                        <Button
                          size="icon-sm"
                          variant="ghost"
                          className="text-muted-foreground hover:text-foreground"
                          onClick={() => openEdit(provider)}
                          aria-label={`Edit ${provider.name}`}
                          title="Edit"
                        >
                          <Pencil className="h-4 w-4" />
                        </Button>
                        <Button
                          size="icon-sm"
                          variant="ghost"
                          className="text-muted-foreground hover:text-red-600 hover:bg-red-500/10"
                          onClick={() => setDeleteTarget(provider)}
                          aria-label={`Delete ${provider.name}`}
                          title="Delete"
                        >
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </div>
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </CardContent>

      {canManage && (
        <OIDCProviderDialog
          orgId={orgId}
          open={dialogOpen}
          onOpenChange={setDialogOpen}
          provider={editTarget}
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
              Members will no longer be able to sign in with this provider.
              Deletion is blocked while user accounts are still linked to it.
              This cannot be undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              className="border-input"
              onClick={() => setDeleteTarget(null)}
              disabled={deleteProvider.isPending}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={handleDelete}
              disabled={deleteProvider.isPending}
            >
              {deleteProvider.isPending ? (
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
