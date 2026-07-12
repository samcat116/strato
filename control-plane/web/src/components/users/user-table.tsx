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
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { EditUserDialog } from "./edit-user-dialog";
import { useDeleteUser, userErrorMessage } from "@/lib/hooks/use-users";
import { toast } from "sonner";
import type { User, UserSource } from "@/types/api";

// How the account was provisioned. `local` accounts are created in Strato
// (admin-added or self-registered); `scim`/`oidc` are owned by an external IdP.
const SOURCE_BADGE: Record<UserSource, { label: string; className: string }> = {
  local: { label: "Local", className: "bg-muted text-foreground/80" },
  scim: { label: "SCIM", className: "bg-blue-500/10 text-blue-700" },
  oidc: { label: "SSO", className: "bg-teal-500/10 text-teal-700" },
};

function SourceBadge({ source }: { source: UserSource }) {
  const { label, className } = SOURCE_BADGE[source] ?? SOURCE_BADGE.local;
  return <Badge className={`${className} border-transparent`}>{label}</Badge>;
}

interface UserTableProps {
  users: User[];
  isLoading?: boolean;
  currentUserId?: string;
}

export function UserTable({ users, isLoading, currentUserId }: UserTableProps) {
  const deleteUser = useDeleteUser();
  const [editTarget, setEditTarget] = useState<User | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<User | null>(null);

  const handleDelete = async () => {
    if (!deleteTarget) return;

    try {
      await deleteUser.mutateAsync(deleteTarget.id);
      toast.success(`User "${deleteTarget.username}" deleted`);
      setDeleteTarget(null);
    } catch (error) {
      toast.error(userErrorMessage(error, "Failed to delete user"));
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

  if (users.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">No users found.</div>
    );
  }

  return (
    <>
      <Table>
        <TableHeader className="bg-background">
          <TableRow className="border-border hover:bg-transparent">
            <TableHead className="text-muted-foreground font-medium">
              Username
            </TableHead>
            <TableHead className="text-muted-foreground font-medium">
              Display Name
            </TableHead>
            <TableHead className="text-muted-foreground font-medium">Email</TableHead>
            <TableHead className="text-muted-foreground font-medium">Role</TableHead>
            <TableHead className="text-muted-foreground font-medium">Source</TableHead>
            <TableHead className="text-muted-foreground font-medium">Created</TableHead>
            <TableHead className="text-muted-foreground font-medium text-right">
              Actions
            </TableHead>
          </TableRow>
        </TableHeader>
        <TableBody className="divide-y divide-border">
          {users.map((user) => (
            <TableRow
              key={user.id}
              className="border-border hover:bg-accent/60"
            >
              <TableCell>
                <span className="font-medium text-foreground">
                  {user.username}
                </span>
                {user.id === currentUserId && (
                  <Badge
                    variant="secondary"
                    className="ml-2 bg-muted text-foreground/80"
                  >
                    You
                  </Badge>
                )}
              </TableCell>
              <TableCell className="text-foreground/80">
                {user.displayName}
              </TableCell>
              <TableCell className="text-foreground/80">{user.email}</TableCell>
              <TableCell>
                {user.isSystemAdmin ? (
                  <Badge className="bg-purple-900/40 text-purple-700 border-transparent">
                    System Admin
                  </Badge>
                ) : (
                  <Badge className="bg-muted text-foreground/80 border-transparent">
                    User
                  </Badge>
                )}
              </TableCell>
              <TableCell>
                <SourceBadge source={user.source} />
              </TableCell>
              <TableCell className="text-muted-foreground text-sm">
                {user.createdAt
                  ? new Date(user.createdAt).toLocaleDateString()
                  : "—"}
              </TableCell>
              <TableCell className="text-right">
                <div className="flex items-center justify-end gap-1">
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    className="text-muted-foreground hover:text-foreground"
                    onClick={() => setEditTarget(user)}
                    aria-label={`Edit ${user.username}`}
                  >
                    <Pencil className="h-4 w-4" />
                  </Button>
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    className="text-muted-foreground hover:text-red-600 hover:bg-red-500/10"
                    onClick={() => setDeleteTarget(user)}
                    aria-label={`Delete ${user.username}`}
                  >
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </div>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>

      {editTarget && (
        <EditUserDialog
          user={editTarget}
          open={!!editTarget}
          onOpenChange={(open) => {
            if (!open) setEditTarget(null);
          }}
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
            <DialogTitle>Delete {deleteTarget?.username}?</DialogTitle>
            <DialogDescription className="text-muted-foreground">
              This will permanently delete the user account and its passkeys.
              This action cannot be undone.
              {deleteTarget?.id === currentUserId && (
                <span className="block mt-2 text-yellow-700">
                  Warning: this is your own account. You will be signed out.
                </span>
              )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              className="border-input"
              onClick={() => setDeleteTarget(null)}
              disabled={deleteUser.isPending}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={handleDelete}
              disabled={deleteUser.isPending}
            >
              {deleteUser.isPending ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Trash2 className="h-4 w-4" />
              )}
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
