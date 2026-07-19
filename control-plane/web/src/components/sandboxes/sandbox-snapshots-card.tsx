"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { GitFork, Loader2 } from "lucide-react";
import { toast } from "sonner";
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
import { useOperationsStore } from "@/lib/stores/operations-store";
import { useProjectContext } from "@/providers";
import type { Sandbox, SandboxSnapshot } from "@/types/api";
import { formatMemory } from "./format";

export function SandboxSnapshotsCard({ sandbox }: { sandbox: Sandbox }) {
  const router = useRouter();
  const { data: snapshots, isLoading, error } = useSandboxSnapshots(sandbox.id);
  const { currentProject } = useProjectContext();
  const watch = useOperationsStore((state) => state.watch);
  const [selected, setSelected] = useState<SandboxSnapshot | null>(null);
  const [name, setName] = useState("");
  const [isForking, setIsForking] = useState(false);

  const beginFork = (snapshot: SandboxSnapshot) => {
    setSelected(snapshot);
    setName(`${sandbox.name}-fork`);
  };

  const submitFork = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!selected || !name.trim()) return;

    setIsForking(true);
    try {
      const operation = await sandboxesApi.create({
        name: name.trim(),
        restoreFrom: selected.id,
        projectId: currentProject?.id ?? sandbox.projectId,
      });
      watch(operation, name.trim());
      toast.success(`Forking sandbox "${name.trim()}"`);
      setSelected(null);
      router.push(`/sandboxes/detail?id=${operation.resourceId}`);
    } catch (forkError) {
      toast.error(
        forkError instanceof Error ? forkError.message : "Failed to fork sandbox"
      );
    } finally {
      setIsForking(false);
    }
  };

  return (
    <>
      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            Snapshots
          </CardTitle>
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
                    </div>
                    <p className="mt-1 text-xs text-muted-foreground">
                      {snapshot.size != null
                        ? formatMemory(snapshot.size)
                        : "Size pending"}
                      {snapshot.createdAt
                        ? ` · ${new Date(snapshot.createdAt).toLocaleString()}`
                        : ""}
                    </p>
                  </div>
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
              ))}
            </div>
          ) : (
            <p className="text-sm text-muted-foreground">
              No snapshots are available to fork.
            </p>
          )}
        </CardContent>
      </Card>

      <Dialog
        open={selected != null}
        onOpenChange={(open) => !open && setSelected(null)}
      >
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Fork from snapshot</DialogTitle>
            <DialogDescription>
              Create a running sandbox from “{selected?.name}” with a new
              identity and network reservation.
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
                The fork is restored on the agent that stores this snapshot.
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
