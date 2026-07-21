"use client";

import { useState } from "react";
import { Check, KeyRound, Loader2, Pencil, Plus, Trash2, X } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  passkeyErrorMessage,
  useAddPasskey,
  useDeletePasskey,
  usePasskeys,
  useRenamePasskey,
} from "@/lib/hooks";
import { useAuth } from "@/providers";
import { toast } from "sonner";
import type { Passkey } from "@/types/api";

function formatDate(value?: string): string {
  if (!value) return "—";
  return new Date(value).toLocaleDateString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

/** Rename in place: the label is the only editable field on a credential. */
function NameCell({ passkey }: { passkey: Passkey }) {
  const rename = useRenamePasskey();
  const [editing, setEditing] = useState(false);
  const [value, setValue] = useState(passkey.name ?? "");

  const save = async () => {
    const trimmed = value.trim();
    try {
      await rename.mutateAsync({ id: passkey.id, name: trimmed || null });
      setEditing(false);
    } catch (error) {
      toast.error(passkeyErrorMessage(error, "Failed to rename passkey"));
    }
  };

  if (!editing) {
    return (
      <div className="flex items-center gap-2">
        <KeyRound className="h-4 w-4 shrink-0 text-muted-foreground" />
        <span className={passkey.name ? "" : "text-muted-foreground"}>
          {passkey.name || "Unnamed passkey"}
        </span>
        <Button
          variant="ghost"
          size="sm"
          aria-label="Rename passkey"
          onClick={() => {
            setValue(passkey.name ?? "");
            setEditing(true);
          }}
        >
          <Pencil className="h-3.5 w-3.5" />
        </Button>
      </div>
    );
  }

  return (
    <div className="flex items-center gap-2">
      <Input
        autoFocus
        value={value}
        maxLength={64}
        placeholder="e.g. MacBook Touch ID"
        className="h-8 w-56"
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") save();
          if (e.key === "Escape") setEditing(false);
        }}
      />
      <Button
        variant="ghost"
        size="sm"
        aria-label="Save name"
        disabled={rename.isPending}
        onClick={save}
      >
        {rename.isPending ? (
          <Loader2 className="h-3.5 w-3.5 animate-spin" />
        ) : (
          <Check className="h-3.5 w-3.5" />
        )}
      </Button>
      <Button
        variant="ghost"
        size="sm"
        aria-label="Cancel rename"
        onClick={() => setEditing(false)}
      >
        <X className="h-3.5 w-3.5" />
      </Button>
    </div>
  );
}

export function PasskeysSection() {
  const { user, isWebAuthnSupported } = useAuth();
  const { data: passkeys = [], isLoading } = usePasskeys();
  const addPasskey = useAddPasskey();
  const deletePasskey = useDeletePasskey();
  const [pendingId, setPendingId] = useState<string | null>(null);

  // Mirrors the server's guard: passkeys are the only local sign-in method, so
  // the last one can't be removed unless the account can also sign in via OIDC.
  const canRemoveLast = user?.source === "oidc";

  const handleAdd = async () => {
    try {
      await addPasskey.mutateAsync(undefined);
      toast.success("Passkey added");
    } catch (error) {
      toast.error(passkeyErrorMessage(error, "Failed to add passkey"));
    }
  };

  const handleDelete = async (passkey: Passkey) => {
    const label = passkey.name || "this passkey";
    if (
      !window.confirm(
        `Remove ${label}? The device it lives on will no longer be able to sign in.`
      )
    ) {
      return;
    }

    setPendingId(passkey.id);
    try {
      await deletePasskey.mutateAsync(passkey.id);
      toast.success("Passkey removed");
    } catch (error) {
      toast.error(passkeyErrorMessage(error, "Failed to remove passkey"));
    } finally {
      setPendingId(null);
    }
  };

  return (
    <Card className="bg-card border-border">
      <CardHeader className="flex flex-row items-center justify-between space-y-0">
        <div>
          <CardTitle className="text-lg font-semibold text-foreground">
            Passkeys
          </CardTitle>
          <p className="text-sm text-muted-foreground">
            Sign in without a password. Add one per device you use.
          </p>
        </div>
        <Button
          onClick={handleAdd}
          disabled={!isWebAuthnSupported || addPasskey.isPending}
        >
          {addPasskey.isPending ? (
            <Loader2 className="mr-2 h-4 w-4 animate-spin" />
          ) : (
            <Plus className="mr-2 h-4 w-4" />
          )}
          Add passkey
        </Button>
      </CardHeader>
      <CardContent>
        {!isWebAuthnSupported && (
          <p className="mb-4 text-sm text-muted-foreground">
            This browser doesn&apos;t support passkeys, so new ones can&apos;t be
            added here.
          </p>
        )}

        {isLoading ? (
          <div className="space-y-2">
            {[...Array(2)].map((_, i) => (
              <Skeleton key={i} className="h-12 w-full bg-muted" />
            ))}
          </div>
        ) : passkeys.length === 0 ? (
          <div className="py-8 text-center text-muted-foreground">
            No passkeys yet.
          </div>
        ) : (
          <Table>
            <TableHeader className="bg-background">
              <TableRow className="border-border hover:bg-transparent">
                <TableHead className="font-medium text-muted-foreground">
                  Name
                </TableHead>
                <TableHead className="font-medium text-muted-foreground">
                  Type
                </TableHead>
                <TableHead className="font-medium text-muted-foreground">
                  Added
                </TableHead>
                <TableHead className="font-medium text-muted-foreground">
                  Last used
                </TableHead>
                <TableHead className="w-16" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {passkeys.map((passkey) => {
                const isLast = passkeys.length === 1;
                const blocked = isLast && !canRemoveLast;
                return (
                  <TableRow key={passkey.id} className="border-border">
                    <TableCell>
                      <NameCell passkey={passkey} />
                    </TableCell>
                    <TableCell>
                      <Badge variant="secondary">
                        {passkey.backedUp ? "Synced" : "Device-bound"}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {formatDate(passkey.createdAt)}
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {formatDate(passkey.lastUsedAt)}
                    </TableCell>
                    <TableCell className="text-right">
                      <Button
                        variant="ghost"
                        size="sm"
                        aria-label="Remove passkey"
                        title={
                          blocked
                            ? "Add another passkey before removing your only one"
                            : "Remove passkey"
                        }
                        disabled={blocked || pendingId === passkey.id}
                        onClick={() => handleDelete(passkey)}
                      >
                        {pendingId === passkey.id ? (
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
        )}
      </CardContent>
    </Card>
  );
}
