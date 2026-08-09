"use client";

import { useState } from "react";
import { Camera, History, Loader2, Trash2 } from "lucide-react";
import { Badge } from "@/components/ui/badge";
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
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { vmsApi } from "@/lib/api/vms";
import { formatMemory } from "@/lib/format-bytes";
import { useVMSnapshots } from "@/lib/hooks";
import { useAcceptedMutation } from "@/lib/hooks/use-accepted-mutation";
import type { VM, VMSnapshot } from "@/types/api";

/**
 * Full-VM checkpoints (issue #564): guest memory, device state, and disks
 * captured at one instant. Distinct from the disk-only volume snapshots in
 * `VMVolumesCard` — restoring one rewinds the running machine, processes and
 * all.
 */
export function VMSnapshotsCard({ vm }: { vm: VM }) {
  const { data: snapshots, isLoading, error } = useVMSnapshots(vm.id);
  const { isLoading: isCreating, run: runCreate } = useAcceptedMutation();
  // Restore and delete share one hook instance: its busyKey carries the id of
  // the row being acted on, and both confirmation dialogs lock while set.
  const { busyKey: busyId, run: runRowAction } = useAcceptedMutation();
  const [showCreate, setShowCreate] = useState(false);
  const [name, setName] = useState("");
  const [restoring, setRestoring] = useState<VMSnapshot | null>(null);
  const [deleting, setDeleting] = useState<VMSnapshot | null>(null);

  // A checkpoint captures live machine state, so there has to be some: a
  // shut-down VM has no QEMU process to read memory from. The server enforces
  // this too; disabling the button explains it before the round trip.
  const canCheckpoint = vm.status === "Running" || vm.status === "Paused";

  const submitCreate = async (event: React.FormEvent) => {
    event.preventDefault();
    const trimmed = name.trim();
    await runCreate({
      request: () =>
        vmsApi.createSnapshot(vm.id, trimmed ? { name: trimmed } : undefined),
      watch: {
        snapshot: true,
        kind: "create",
        resourceKind: "vm_checkpoint",
        resourceName: trimmed || `${vm.name} checkpoint`,
      },
      errorMessage: "Failed to checkpoint VM",
      successMessage: "Checkpointing VM",
      onSuccess: () => {
        setShowCreate(false);
        setName("");
      },
    });
  };

  const submitRestore = async () => {
    if (!restoring) return;
    // A restore acts on the VM, so it is watched as a VM mutation — the
    // checkpoint itself does not change (backend STR-151).
    await runRowAction({
      busyKey: restoring.id,
      request: () => vmsApi.restoreSnapshot(vm.id, restoring.id),
      watch: {
        kind: "restore",
        resourceKind: "virtual_machine",
        resourceName: vm.name,
      },
      errorMessage: "Failed to restore checkpoint",
      successMessage: `Restoring “${restoring.name}”`,
      onSuccess: () => setRestoring(null),
    });
  };

  const submitDelete = async () => {
    if (!deleting) return;
    const snapshot = deleting;
    await runRowAction({
      busyKey: snapshot.id,
      request: () => vmsApi.deleteSnapshot(vm.id, snapshot.id),
      watch: {
        snapshot: true,
        kind: "delete",
        resourceKind: "vm_checkpoint",
        resourceName: snapshot.name,
      },
      errorMessage: "Failed to delete checkpoint",
      successMessage: `Deleting “${snapshot.name}”`,
      onSuccess: () => setDeleting(null),
    });
  };

  return (
    <>
      <Card className="bg-card border-border">
        <CardHeader className="flex flex-row items-center justify-between space-y-0">
          <div>
            <CardTitle className="text-lg font-semibold text-foreground">
              Checkpoints
            </CardTitle>
            <p className="mt-1 text-sm text-muted-foreground">
              Memory, device state, and disks captured together. Restoring one
              rewinds the guest to that exact moment.
            </p>
          </div>
          <Button
            size="sm"
            disabled={!canCheckpoint}
            onClick={() => setShowCreate(true)}
            title={
              canCheckpoint
                ? "Capture the VM's current memory and disk state"
                : "The VM must be running or paused to be checkpointed"
            }
          >
            <Camera className="h-4 w-4 mr-2" />
            Checkpoint
          </Button>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <Loader2 className="h-4 w-4 animate-spin" />
              Loading checkpoints…
            </div>
          ) : error ? (
            <p className="text-sm text-red-600">Failed to load checkpoints.</p>
          ) : snapshots?.length ? (
            <div className="divide-y divide-border">
              {snapshots.map((snapshot) => (
                <div
                  key={snapshot.id}
                  className="flex items-center justify-between gap-4 py-4 first:pt-0 last:pb-0"
                >
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <p className="font-medium text-foreground truncate">
                        {snapshot.name}
                      </p>
                      <Badge
                        variant={
                          snapshot.status === "ready"
                            ? "default"
                            : snapshot.status === "error"
                              ? "destructive"
                              : "secondary"
                        }
                      >
                        {snapshot.status}
                      </Badge>
                    </div>
                    <p className="mt-1 text-xs text-muted-foreground">
                      {snapshot.size != null
                        ? formatMemory(snapshot.size)
                        : "Size pending"}
                      {snapshot.createdAt
                        ? ` · ${new Date(snapshot.createdAt).toLocaleString()}`
                        : ""}
                      {snapshot.qemuVersion
                        ? ` · QEMU ${snapshot.qemuVersion}`
                        : ""}
                    </p>
                    {snapshot.errorMessage && (
                      <p className="mt-1 text-xs text-red-600">
                        {snapshot.errorMessage}
                      </p>
                    )}
                  </div>
                  <div className="flex items-center gap-2">
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={
                        snapshot.status !== "ready" || busyId === snapshot.id
                      }
                      onClick={() => setRestoring(snapshot)}
                    >
                      <History className="h-4 w-4 mr-2" />
                      Restore
                    </Button>
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={
                        snapshot.status === "creating" || busyId === snapshot.id
                      }
                      onClick={() => setDeleting(snapshot)}
                      aria-label={`Delete checkpoint ${snapshot.name}`}
                    >
                      {busyId === snapshot.id ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <Trash2 className="h-4 w-4" />
                      )}
                    </Button>
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <p className="text-sm text-muted-foreground">
              No checkpoints yet.
            </p>
          )}
        </CardContent>
      </Card>

      <Dialog open={showCreate} onOpenChange={setShowCreate}>
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Checkpoint this VM</DialogTitle>
            <DialogDescription>
              Captures “{vm.name}” exactly as it is now — memory, devices, and
              disks. The guest keeps running; it pauses only while the state is
              written.
            </DialogDescription>
          </DialogHeader>
          <form onSubmit={submitCreate}>
            <div className="space-y-2 py-4">
              <Label htmlFor="vm-checkpoint-name">Name (optional)</Label>
              <Input
                id="vm-checkpoint-name"
                value={name}
                onChange={(event) => setName(event.target.value)}
                placeholder="before-upgrade"
                disabled={isCreating}
                autoFocus
              />
              <p className="text-xs text-muted-foreground">
                The checkpoint is stored inside this VM&apos;s disks, on the
                agent it runs on, and cannot be moved to another host.
              </p>
            </div>
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={() => setShowCreate(false)}
                disabled={isCreating}
              >
                Cancel
              </Button>
              <Button type="submit" disabled={isCreating}>
                {isCreating && (
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                )}
                Checkpoint
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      <Dialog
        open={deleting != null}
        onOpenChange={(open) => !open && setDeleting(null)}
      >
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Delete checkpoint</DialogTitle>
            <DialogDescription>
              “{deleting?.name}” is removed from the VM&apos;s disks. The
              captured memory and device state are gone for good — this is as
              irreversible as restoring, and there is no copy anywhere else.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => setDeleting(null)}
              disabled={busyId != null}
            >
              Cancel
            </Button>
            <Button
              type="button"
              variant="destructive"
              onClick={submitDelete}
              disabled={busyId != null}
            >
              {busyId != null && (
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
              )}
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog
        open={restoring != null}
        onOpenChange={(open) => !open && setRestoring(null)}
      >
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Restore from checkpoint</DialogTitle>
            <DialogDescription>
              “{restoring?.name}” replaces the VM&apos;s current memory and disk
              state. Everything the guest has done since the checkpoint is
              lost, and open network connections will not survive the rewind.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => setRestoring(null)}
              disabled={busyId != null}
            >
              Cancel
            </Button>
            <Button
              type="button"
              variant="destructive"
              onClick={submitRestore}
              disabled={busyId != null}
            >
              {busyId != null && (
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
              )}
              Restore
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
