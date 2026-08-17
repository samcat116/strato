"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Camera, CloudUpload, GitFork, Loader2 } from "lucide-react";
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
import { sandboxesApi } from "@/lib/api/sandboxes";
import { useSandboxSnapshots } from "@/lib/hooks";
import { useAcceptedMutation } from "@/lib/hooks/use-accepted-mutation";
import { usePermissions } from "@/lib/hooks/use-permissions";
import { sandboxCanBeSnapshotted } from "@/lib/sandbox-guards";
import { useProjectContext } from "@/providers";
import type { Sandbox, SandboxSnapshot } from "@/types/api";
import { formatMemory } from "@/lib/format-bytes";
import { toast } from "sonner";

export function SandboxSnapshotsCard({ sandbox }: { sandbox: Sandbox }) {
  const router = useRouter();
  const { data: snapshots, isLoading, error } = useSandboxSnapshots(sandbox.id);
  const { currentProject } = useProjectContext();
  const [showCreate, setShowCreate] = useState(false);
  const [snapshotName, setSnapshotName] = useState("");
  const [stopAfterSnapshot, setStopAfterSnapshot] = useState(false);
  const [selected, setSelected] = useState<SandboxSnapshot | null>(null);
  const [name, setName] = useState("");
  const { isLoading: isCreating, run: runCreate } = useAcceptedMutation();
  const { isLoading: isForking, run: runFork } = useAcceptedMutation();
  const { busyKey: exportingId, run: runExport } = useAcceptedMutation();
  const { permissions } = usePermissions([
    {
      key: "snapshot",
      action: "sandbox:snapshot",
      node: { type: "sandbox", id: sandbox.id },
    },
  ]);
  const canSnapshot = sandboxCanBeSnapshotted(sandbox);

  const submitCreate = async (event: React.FormEvent) => {
    event.preventDefault();
    const trimmedName = snapshotName.trim();

    await runCreate({
      request: () =>
        sandboxesApi.createSnapshot(sandbox.id, {
          name: trimmedName || undefined,
          stop: stopAfterSnapshot || undefined,
        }),
      watch: {
        snapshot: true,
        kind: "create",
        resourceKind: "sandbox_snapshot",
        resourceName: trimmedName || `${sandbox.name} snapshot`,
      },
      errorMessage: "Failed to snapshot sandbox",
      successMessage: stopAfterSnapshot
        ? `Snapshotting and stopping “${sandbox.name}”`
        : `Snapshotting “${sandbox.name}”`,
      onSuccess: () => {
        setShowCreate(false);
        setSnapshotName("");
        setStopAfterSnapshot(false);
      },
    });
  };

  const beginFork = (snapshot: SandboxSnapshot) => {
    setSelected(snapshot);
    setName(`${sandbox.name}-fork`);
  };

  // Export records that the snapshot's artifacts should also exist in
  // control-plane object storage (issue #428): the checkpoint survives agent
  // loss and becomes eligible for cross-agent restore and fork. A placement
  // fact rather than a command since STR-150 — the owning agent converges by
  // uploading, and the snapshot stays unconverged until every artifact lands.
  const exportSnapshot = (snapshot: SandboxSnapshot) =>
    runExport({
      busyKey: snapshot.id,
      request: () => sandboxesApi.exportSnapshot(sandbox.id, snapshot.id),
      watch: {
        snapshot: true,
        kind: "snapshot_export",
        resourceKind: "sandbox_snapshot",
        resourceName: `${snapshot.name} export`,
      },
      errorMessage: "Failed to export snapshot",
      successMessage: `Exporting snapshot "${snapshot.name}"`,
    });

  const submitFork = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!selected || !name.trim()) return;

    // A fork stays with its source sandbox by default. In particular, a
    // networked snapshot cannot silently follow the header switcher into a
    // different project without also naming a new network.
    const projectId = sandbox.projectId ?? currentProject?.id;
    if (!projectId) {
      toast.error("Select a project first");
      return;
    }

    // A fork is an ordinary sandbox create, so it answers with the new
    // sandbox rather than an operation.
    await runFork({
      request: () =>
        sandboxesApi.create({
          name: name.trim(),
          restoreFrom: selected.id,
          projectId,
        }),
      watch: {
        kind: "create",
        resourceKind: "sandbox",
        resourceName: name.trim(),
      },
      errorMessage: "Failed to fork sandbox",
      successMessage: `Forking sandbox "${name.trim()}"`,
      onSuccess: (accepted) => {
        setSelected(null);
        router.push(`/sandboxes/${accepted.resource.id}`);
      },
    });
  };

  return (
    <>
      <Card className="bg-card border-border">
        <CardHeader className="flex flex-row items-center justify-between space-y-0">
          <div>
            <CardTitle className="text-lg font-semibold text-foreground">
              Snapshots
            </CardTitle>
            <p className="mt-1 text-sm text-muted-foreground">
              Memory, device state, and the root filesystem captured together.
            </p>
          </div>
          {permissions.snapshot && (
            <Button
              size="sm"
              disabled={!canSnapshot}
              onClick={() => setShowCreate(true)}
              title={
                canSnapshot
                  ? "Capture the sandbox's current state"
                  : "Wait for an agent to place and confirm the sandbox before taking a snapshot"
              }
            >
              <Camera className="h-4 w-4 mr-2" />
              Take snapshot
            </Button>
          )}
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <Loader2 className="h-4 w-4 animate-spin" />
              Loading snapshots…
            </div>
          ) : error ? (
            <p className="text-sm text-red-600">Failed to load snapshots.</p>
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
                          snapshot.status === "ready" ? "default" : "secondary"
                        }
                      >
                        {snapshot.status}
                      </Badge>
                      {snapshot.exportedAt && (
                        <Badge variant="outline">exported</Badge>
                      )}
                    </div>
                    <p className="mt-1 text-xs text-muted-foreground">
                      {snapshot.size != null
                        ? formatMemory(snapshot.size)
                        : "Size pending"}
                      {snapshot.createdAt
                        ? ` · ${new Date(snapshot.createdAt).toLocaleString()}`
                        : ""}
                      {snapshot.cpuTemplate
                        ? ` · ${snapshot.cpuTemplate} template`
                        : ""}
                    </p>
                  </div>
                  <div className="flex items-center gap-2">
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={
                        snapshot.status !== "ready" ||
                        exportingId === snapshot.id
                      }
                      onClick={() => exportSnapshot(snapshot)}
                      title="Copy this snapshot to object storage so it survives agent loss and can restore or fork on other agents"
                    >
                      {exportingId === snapshot.id ? (
                        <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                      ) : (
                        <CloudUpload className="h-4 w-4 mr-2" />
                      )}
                      Export
                    </Button>
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={snapshot.status !== "ready"}
                      onClick={() => beginFork(snapshot)}
                    >
                      <GitFork className="h-4 w-4 mr-2" />
                      Fork
                    </Button>
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <p className="text-sm text-muted-foreground">
              No snapshots yet.
            </p>
          )}
        </CardContent>
      </Card>

      <Dialog open={showCreate} onOpenChange={setShowCreate}>
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Take a snapshot</DialogTitle>
            <DialogDescription>
              Capture “{sandbox.name}” as it is now, including its memory,
              device state, and root filesystem.
            </DialogDescription>
          </DialogHeader>
          <form onSubmit={submitCreate}>
            <div className="space-y-4 py-4">
              <div className="space-y-2">
                <Label htmlFor="sandbox-snapshot-name">Name (optional)</Label>
                <Input
                  id="sandbox-snapshot-name"
                  value={snapshotName}
                  onChange={(event) => setSnapshotName(event.target.value)}
                  placeholder="before-upgrade"
                  disabled={isCreating}
                  autoFocus
                />
              </div>
              <label className="flex items-start gap-3 text-sm text-foreground">
                <input
                  type="checkbox"
                  checked={stopAfterSnapshot}
                  onChange={(event) =>
                    setStopAfterSnapshot(event.target.checked)
                  }
                  disabled={isCreating}
                  className="mt-0.5 h-4 w-4 rounded border-input bg-background accent-blue-600"
                />
                <span>
                  <span className="font-medium">Stop after snapshot</span>
                  <span className="mt-1 block text-xs text-muted-foreground">
                    Leave the sandbox stopped after its state is captured.
                    Otherwise it resumes automatically.
                  </span>
                </span>
              </label>
              <p className="text-xs text-muted-foreground">
                The snapshot starts on this sandbox&apos;s agent. Export it
                afterward to keep a copy in object storage and use it on other
                compatible agents.
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
                {stopAfterSnapshot ? "Snapshot and stop" : "Take snapshot"}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      <Dialog
        open={selected != null}
        onOpenChange={(open) => !open && setSelected(null)}
      >
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Fork from snapshot</DialogTitle>
            <DialogDescription>
              Create a running sandbox from “{selected?.name}” with a new
              identity in the source sandbox&apos;s project.
            </DialogDescription>
          </DialogHeader>
          <form onSubmit={submitFork}>
            <div className="space-y-2 py-4">
              <Label htmlFor="fork-sandbox-name">Sandbox name</Label>
              <Input
                id="fork-sandbox-name"
                value={name}
                onChange={(event) => setName(event.target.value)}
                disabled={isForking}
                autoFocus
              />
              <p className="text-xs text-muted-foreground">
                {selected?.exportedAt
                  ? "The fork can restore on any compatible agent (the snapshot is exported)."
                  : "The fork is restored on the agent that stores this snapshot; export the snapshot to fan out across agents."}{" "}
                Open TCP connections from the source are not portable.
              </p>
            </div>
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={() => setSelected(null)}
                disabled={isForking}
              >
                Cancel
              </Button>
              <Button type="submit" disabled={isForking || !name.trim()}>
                {isForking && <Loader2 className="h-4 w-4 mr-2 animate-spin" />}
                Fork sandbox
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </>
  );
}
