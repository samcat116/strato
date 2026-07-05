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
import type { User } from "@/types/api";

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
          <Skeleton key={i} className="h-12 w-full bg-gray-700" />
        ))}
      </div>
    );
  }

  if (users.length === 0) {
    return (
      <div className="text-center py-8 text-gray-400">No users found.</div>
    );
  }

  return (
    <>
      <Table>
        <TableHeader className="bg-gray-900">
          <TableRow className="border-gray-700 hover:bg-gray-900">
            <TableHead className="text-gray-400 font-medium">
              Username
            </TableHead>
            <TableHead className="text-gray-400 font-medium">
              Display Name
            </TableHead>
            <TableHead className="text-gray-400 font-medium">Email</TableHead>
            <TableHead className="text-gray-400 font-medium">Role</TableHead>
            <TableHead className="text-gray-400 font-medium">Created</TableHead>
            <TableHead className="text-gray-400 font-medium text-right">
              Actions
            </TableHead>
          </TableRow>
        </TableHeader>
        <TableBody className="divide-y divide-gray-700">
          {users.map((user) => (
            <TableRow
              key={user.id}
              className="border-gray-700 hover:bg-gray-800/50"
            >
              <TableCell>
                <span className="font-medium text-gray-100">
                  {user.username}
                </span>
                {user.id === currentUserId && (
                  <Badge
                    variant="secondary"
                    className="ml-2 bg-gray-700 text-gray-300"
                  >
                    You
                  </Badge>
                )}
              </TableCell>
              <TableCell className="text-gray-300">
                {user.displayName}
              </TableCell>
              <TableCell className="text-gray-300">{user.email}</TableCell>
              <TableCell>
                {user.isSystemAdmin ? (
                  <Badge className="bg-purple-900/40 text-purple-300 border-transparent">
                    System Admin
                  </Badge>
                ) : (
                  <Badge className="bg-gray-700 text-gray-300 border-transparent">
                    User
                  </Badge>
                )}
              </TableCell>
              <TableCell className="text-gray-400 text-sm">
                {user.createdAt
                  ? new Date(user.createdAt).toLocaleDateString()
                  : "—"}
              </TableCell>
              <TableCell className="text-right">
                <div className="flex items-center justify-end gap-1">
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    className="text-gray-400 hover:text-gray-100"
                    onClick={() => setEditTarget(user)}
                    aria-label={`Edit ${user.username}`}
                  >
                    <Pencil className="h-4 w-4" />
                  </Button>
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    className="text-gray-400 hover:text-red-400 hover:bg-red-950/30"
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
        <DialogContent className="bg-gray-800 border-gray-700 text-gray-100">
          <DialogHeader>
            <DialogTitle>Delete {deleteTarget?.username}?</DialogTitle>
            <DialogDescription className="text-gray-400">
              This will permanently delete the user account and its passkeys.
              This action cannot be undone.
              {deleteTarget?.id === currentUserId && (
                <span className="block mt-2 text-yellow-400">
                  Warning: this is your own account. You will be signed out.
                </span>
              )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              className="border-gray-600"
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
