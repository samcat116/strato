"use client";

import { useMemo, useState } from "react";
import { Loader2, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
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
import { Skeleton } from "@/components/ui/skeleton";
import { volumesApi } from "@/lib/api/volumes";
import { toast } from "sonner";
import type { Volume, VolumeSnapshot } from "@/types/api";
import { SnapshotStatusBadge } from "./snapshot-status-badge";

interface SnapshotTableProps {
  snapshots: VolumeSnapshot[];
  volumes: Volume[];
  isLoading?: boolean;
  onRefresh?: () => void;
  /** Hide the Volume column when the table is scoped to a single volume. */
  showVolumeColumn?: boolean;
}

export function SnapshotTable({
  snapshots,
  volumes,
  isLoading,
  onRefresh,
  showVolumeColumn = true,
}: SnapshotTableProps) {
  const [deleteTarget, setDeleteTarget] = useState<VolumeSnapshot | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);

  const volumesById = useMemo(
    () => new Map(volumes.filter((v) => v.id).map((v) => [v.id!, v])),
    [volumes]
  );

  const handleDelete = async () => {
    if (!deleteTarget?.id || !deleteTarget.volumeId) return;
    setIsDeleting(true);
    try {
      await volumesApi.deleteSnapshot(deleteTarget.volumeId, deleteTarget.id);
      toast.success(`Deleted snapshot ${deleteTarget.name}`);
      setDeleteTarget(null);
      onRefresh?.();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to delete snapshot"
      );
    } finally {
      setIsDeleting(false);
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

  if (snapshots.length === 0) {
    return (
      <div className="text-center py-8 text-gray-400">
        No snapshots found. Snapshot a volume to get started.
      </div>
    );
  }

  const canDelete = (snapshot: VolumeSnapshot) =>
    snapshot.status === "available" ||
    snapshot.status === "error" ||
    snapshot.status === "deleting";

  return (
    <>
      <Table>
        <TableHeader className="bg-gray-900">
          <TableRow className="border-gray-700 hover:bg-gray-900">
            <TableHead className="text-gray-400 font-medium">Name</TableHead>
            {showVolumeColumn && (
              <TableHead className="text-gray-400 font-medium">
                Volume
              </TableHead>
            )}
            <TableHead className="text-gray-400 font-medium">Status</TableHead>
            <TableHead className="text-gray-400 font-medium">Size</TableHead>
            <TableHead className="text-gray-400 font-medium">Created</TableHead>
            <TableHead className="text-gray-400 font-medium text-right">
              Actions
            </TableHead>
          </TableRow>
        </TableHeader>
        <TableBody className="divide-y divide-gray-700">
          {snapshots.map((snapshot) => {
            const volume = snapshot.volumeId
              ? volumesById.get(snapshot.volumeId)
              : undefined;
            return (
              <TableRow
                key={snapshot.id}
                className="border-gray-700 hover:bg-gray-800/50"
              >
                <TableCell>
                  <span className="font-medium text-gray-100">
                    {snapshot.name}
                  </span>
                  {snapshot.description && (
                    <p className="text-sm text-gray-500 truncate max-w-xs">
                      {snapshot.description}
                    </p>
                  )}
                  {snapshot.status === "error" && snapshot.errorMessage && (
                    <p className="text-sm text-red-400 truncate max-w-xs">
                      {snapshot.errorMessage}
                    </p>
                  )}
                </TableCell>
                {showVolumeColumn && (
                  <TableCell className="text-gray-300">
                    {volume?.name ?? (
                      <span className="text-gray-500 font-mono text-sm">
                        {snapshot.volumeId ?? "—"}
                      </span>
                    )}
                  </TableCell>
                )}
                <TableCell>
                  <SnapshotStatusBadge status={snapshot.status} />
                </TableCell>
                <TableCell className="text-gray-300">
                  {snapshot.sizeFormatted}
                </TableCell>
                <TableCell className="text-gray-300">
                  {snapshot.createdAt
                    ? new Date(snapshot.createdAt).toLocaleString()
                    : "—"}
                </TableCell>
                <TableCell className="text-right">
                  <Button
                    size="sm"
                    variant="ghost"
                    className="text-red-400 hover:text-red-300 hover:bg-red-500/10"
                    onClick={() => setDeleteTarget(snapshot)}
                    disabled={!canDelete(snapshot)}
                  >
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </TableCell>
              </TableRow>
            );
          })}
        </TableBody>
      </Table>

      {/* Delete confirmation dialog */}
      <Dialog
        open={!!deleteTarget}
        onOpenChange={(open) => !open && setDeleteTarget(null)}
      >
        <DialogContent className="bg-gray-800 border-gray-700 text-gray-100">
          <DialogHeader>
            <DialogTitle>Delete snapshot {deleteTarget?.name}?</DialogTitle>
            <DialogDescription className="text-gray-400">
              This will permanently delete the snapshot. This action cannot be
              undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setDeleteTarget(null)}
              className="border-gray-600 text-gray-300 hover:bg-gray-700"
              disabled={isDeleting}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={handleDelete}
              disabled={isDeleting}
            >
              {isDeleting ? (
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
