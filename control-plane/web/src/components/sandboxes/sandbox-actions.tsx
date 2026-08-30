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
import { useAcceptedMutation } from "@/lib/hooks/use-accepted-mutation";
import { usePendingMutation } from "@/lib/stores/mutations-store";
import { usePermissions } from "@/lib/hooks/use-permissions";
import { toast } from "sonner";
import type { Sandbox, OperationKind } from "@/types/api";

interface SandboxActionsProps {
  sandbox: Sandbox;
  onActionComplete?: () => void;
  allowedActions?: Partial<Record<SandboxAction, boolean>>;
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
  run: null,
};

export function SandboxActions({
  sandbox,
  onActionComplete,
  allowedActions,
}: SandboxActionsProps) {
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const {
    isLoading: isSubmitting,
    busyKey: submittingAction,
    run,
  } = useAcceptedMutation();
  const pendingMutation = usePendingMutation(sandbox.id);
  const { permissions: queriedPermissions } = usePermissions(
    allowedActions ? [] : (["start", "stop", "restart", "delete"] as SandboxAction[]).map((action) => ({
      key: action,
      action: `sandbox:${action}`,
      node: { type: "sandbox", id: sandbox.id },
    }))
  );
  const permissions = allowedActions ?? queriedPermissions;

  // Busy while the request is in flight OR while an accepted mutation is still
  // converging on the server — mutations no longer resolve synchronously.
  const isLoading = isSubmitting || !!pendingMutation;
  const activeAction =
    submittingAction ??
    (pendingMutation ? kindToAction[pendingMutation.kind] : null);

  const handleAction = (action: SandboxAction) =>
    // Each call returns 202; the MutationWatcher follows it to a terminal
    // state and toasts the outcome.
    run({
      busyKey: action,
      request: () => sandboxesApi[action](sandbox.id),
      watch: {
        kind: actionToKind[action],
        resourceKind: "sandbox",
        resourceName: sandbox.name,
      },
      errorMessage: `Failed to ${action} sandbox`,
      onSuccess: () => {
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
      },
    });

  // Mirrors the backend's Sandbox.canStart: `Exited` (re-run a one-shot
  // workload) and `Error` (recover an unconfirmed sandbox) are both startable.
  const canStart =
    sandbox.status === "Stopped" ||
    sandbox.status === "Exited" ||
    sandbox.status === "Error";
  // Mirrors Sandbox.canStop: `Error` means the agent could not confirm the
  // sandbox, which is very often a guest that is still running. Without this
  // the API accepts the stop but the UI offers no way to ask for it, leaving
  // deletion as the only way out (STR-194).
  const canStop = sandbox.status === "Running" || sandbox.status === "Error";

  return (
    <div className="flex items-center space-x-2">
      {/* Quick actions */}
      {canStart && permissions.start && (
        <Button
          size="sm"
          variant="ghost"
          className="text-green-600 hover:text-green-700 hover:bg-green-500/10"
          onClick={() => handleAction("start")}
          disabled={isLoading}
          aria-label={`Start ${sandbox.name}`}
        >
          {activeAction === "start" ? (
            <Loader2 className="h-4 w-4 animate-spin" />
          ) : (
            <Play className="h-4 w-4" />
          )}
        </Button>
      )}
      {canStop && permissions.stop && (
        <Button
          size="sm"
          variant="ghost"
          className="text-red-600 hover:text-red-700 hover:bg-red-500/10"
          onClick={() => handleAction("stop")}
          disabled={isLoading}
          aria-label={`Stop ${sandbox.name}`}
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
            aria-label={`More actions for ${sandbox.name}`}
          >
            <MoreHorizontal className="h-4 w-4" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent className="bg-card border-border">
          {canStart && permissions.start && (
            <DropdownMenuItem
              onClick={() => handleAction("start")}
              className="text-foreground hover:bg-accent cursor-pointer"
            >
              <Play className="h-4 w-4 mr-2 text-green-600" />
              Start
            </DropdownMenuItem>
          )}
          {canStop && permissions.stop && (
            <DropdownMenuItem
              onClick={() => handleAction("stop")}
              className="text-foreground hover:bg-accent cursor-pointer"
            >
              <Square className="h-4 w-4 mr-2 text-red-600" />
              Stop
            </DropdownMenuItem>
          )}
          {permissions.restart && <DropdownMenuItem
            onClick={() => handleAction("restart")}
            className="text-foreground hover:bg-accent cursor-pointer"
            disabled={sandbox.status !== "Running"}
          >
            <RotateCcw className="h-4 w-4 mr-2 text-blue-600" />
            Restart
          </DropdownMenuItem>}
          {permissions.delete && <DropdownMenuSeparator className="bg-muted" />}
          {permissions.delete && <DropdownMenuItem
            onClick={() => setShowDeleteConfirm(true)}
            className="text-red-600 hover:bg-red-500/10 cursor-pointer"
          >
            <Trash2 className="h-4 w-4 mr-2" />
            Delete
          </DropdownMenuItem>}
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
