"use client";

import { useState } from "react";
import {
  Play,
  Square,
  RotateCcw,
  Trash2,
  MoreHorizontal,
  Loader2,
} from "lucide-react";
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
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { sandboxesApi } from "@/lib/api/sandboxes";
import { friendlyErrorMessage } from "@/lib/errors";
import {
  acceptedMutation,
  usePendingMutation,
  useMutationsStore,
} from "@/lib/stores/mutations-store";
import { toast } from "sonner";
import type { Sandbox, OperationKind } from "@/types/api";

interface SandboxActionsProps {
  sandbox: Sandbox;
  onActionComplete?: () => void;
}

type SandboxAction = "start" | "stop" | "restart" | "delete";

// The verb each button reports, since a lifecycle mutation answers with the
// sandbox rather than an operation that names its own kind. Unlike a VM's,
// every sandbox verb here is generation-backed — restart included, because it
// rides the desired-state sync.
const actionToKind: Record<SandboxAction, OperationKind> = {
  start: "boot",
  stop: "shutdown",
  restart: "reboot",
  delete: "delete",
};

// The other direction: maps an in-flight mutation (which may have been started
// elsewhere, e.g. on the detail page) back to the action button that should
// show the spinner. Sandboxes never pause/resume, but the map stays total over
// OperationKind.
const kindToAction: Record<OperationKind, SandboxAction | null> = {
  create: null,
  boot: "start",
  shutdown: "stop",
  reboot: "restart",
  pause: null,
  resume: null,
  delete: "delete",
  // VM-only, but the map stays total over OperationKind.
  resize: null,
  snapshot: null,
  snapshot_delete: null,
  restore: null,
  // Export is driven from the snapshot card, not a lifecycle button.
  snapshot_export: null,
  // Volume-only kinds (backend STR-148, STR-19); sandboxes never carry them,
  // but the map stays total.
  attach: null,
  detach: null,
  throttle: null,
};

export function SandboxActions({
  sandbox,
  onActionComplete,
}: SandboxActionsProps) {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [submittingAction, setSubmittingAction] = useState<string | null>(null);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const watch = useMutationsStore((state) => state.watch);
  const pendingMutation = usePendingMutation(sandbox.id);

  // Busy while the request is in flight OR while an accepted mutation is still
  // converging on the server — mutations no longer resolve synchronously.
  const isLoading = isSubmitting || !!pendingMutation;
  const activeAction =
    submittingAction ??
    (pendingMutation ? kindToAction[pendingMutation.kind] : null);

  const handleAction = async (action: SandboxAction) => {
    setIsSubmitting(true);
    setSubmittingAction(action);

    try {
      // Each call returns 202; the MutationWatcher follows it to a terminal
      // state and toasts the outcome.
      watch(
        acceptedMutation(await sandboxesApi[action](sandbox.id), {
          kind: actionToKind[action],
          resourceKind: "sandbox",
          resourceName: sandbox.name,
        })
      );

      switch (action) {
        case "start":
          toast.success(`Starting ${sandbox.name}`);
          break;
        case "stop":
          toast.success(`Stopping ${sandbox.name}`);
          break;
        case "restart":
          toast.success(`Restarting ${sandbox.name}`);
          break;
        case "delete":
          setShowDeleteConfirm(false);
          toast.success(`Deleting ${sandbox.name}`);
          break;
      }
      onActionComplete?.();
    } catch (error) {
      toast.error(friendlyErrorMessage(error, `Failed to ${action} sandbox`));
    } finally {
      setIsSubmitting(false);
      setSubmittingAction(null);
    }
  };

  // Mirrors the backend's Sandbox.canStart: `Exited` (re-run a one-shot
  // workload) and `Error` (recover an unconfirmed sandbox) are both startable.
  const canStart =
    sandbox.status === "Stopped" ||
    sandbox.status === "Exited" ||
    sandbox.status === "Error";
  const canStop = sandbox.status === "Running";

  return (
    <div className="flex items-center space-x-2">
      {/* Quick actions */}
      {canStart && (
        <Button
          size="sm"
          variant="ghost"
          className="text-green-600 hover:text-green-700 hover:bg-green-500/10"
          onClick={() => handleAction("start")}
          disabled={isLoading}
        >
          {activeAction === "start" ? (
            <Loader2 className="h-4 w-4 animate-spin" />
          ) : (
            <Play className="h-4 w-4" />
          )}
        </Button>
      )}
      {canStop && (
        <Button
          size="sm"
          variant="ghost"
          className="text-red-600 hover:text-red-700 hover:bg-red-500/10"
          onClick={() => handleAction("stop")}
          disabled={isLoading}
        >
          {activeAction === "stop" ? (
            <Loader2 className="h-4 w-4 animate-spin" />
          ) : (
            <Square className="h-4 w-4" />
          )}
        </Button>
      )}

      {/* More actions dropdown */}
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button
            size="sm"
            variant="ghost"
            className="text-muted-foreground hover:text-foreground"
            disabled={isLoading}
          >
            <MoreHorizontal className="h-4 w-4" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent className="bg-card border-border">
          {canStart && (
            <DropdownMenuItem
              onClick={() => handleAction("start")}
              className="text-foreground hover:bg-accent cursor-pointer"
            >
              <Play className="h-4 w-4 mr-2 text-green-600" />
              Start
            </DropdownMenuItem>
          )}
          {canStop && (
            <DropdownMenuItem
              onClick={() => handleAction("stop")}
              className="text-foreground hover:bg-accent cursor-pointer"
            >
              <Square className="h-4 w-4 mr-2 text-red-600" />
              Stop
            </DropdownMenuItem>
          )}
          <DropdownMenuItem
            onClick={() => handleAction("restart")}
            className="text-foreground hover:bg-accent cursor-pointer"
            disabled={sandbox.status !== "Running"}
          >
            <RotateCcw className="h-4 w-4 mr-2 text-blue-600" />
            Restart
          </DropdownMenuItem>
          <DropdownMenuSeparator className="bg-muted" />
          <DropdownMenuItem
            onClick={() => setShowDeleteConfirm(true)}
            className="text-red-600 hover:bg-red-500/10 cursor-pointer"
          >
            <Trash2 className="h-4 w-4 mr-2" />
            Delete
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>

      {/* Delete confirmation dialog */}
      <Dialog open={showDeleteConfirm} onOpenChange={setShowDeleteConfirm}>
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Delete {sandbox.name}?</DialogTitle>
            <DialogDescription className="text-muted-foreground">
              This will permanently delete the sandbox. This action cannot be
              undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setShowDeleteConfirm(false)}
              disabled={isLoading}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={() => handleAction("delete")}
              disabled={isLoading}
            >
              {activeAction === "delete" ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Trash2 className="h-4 w-4" />
              )}
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
