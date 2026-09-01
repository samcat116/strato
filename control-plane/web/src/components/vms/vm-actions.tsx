"use client";

import { useState } from "react";
import {
  Play,
  Square,
  RotateCcw,
  Pause,
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
import { vmsApi } from "@/lib/api/vms";
import { useAcceptedMutation } from "@/lib/hooks/use-accepted-mutation";
import { usePendingMutation } from "@/lib/stores/mutations-store";
import { usePermissions } from "@/lib/hooks/use-permissions";
import { toast } from "sonner";
import type { VM, OperationKind } from "@/types/api";

interface VMActionsProps {
  vm: VM;
  onActionComplete?: () => void;
  allowedActions?: Partial<Record<VMAction, boolean>>;
}

type VMAction = "start" | "stop" | "restart" | "pause" | "resume" | "delete";

// Maps an in-flight mutation (which may have been started elsewhere, e.g. on
// the detail page) back to the action button that should show the spinner.
// The other direction: a mutation answers with the VM rather than an operation,
// so the verb the toast reports has to come from the button that was pressed.
// Every VM verb is generation-backed now — restart included, since backend
// STR-151 made a reboot a nonce on the VM's desired entry.
const actionToKind: Record<VMAction, OperationKind> = {
  start: "boot",
  stop: "shutdown",
  restart: "reboot",
  pause: "pause",
  resume: "resume",
  delete: "delete",
};

const kindToAction: Record<OperationKind, VMAction | null> = {
  create: null,
  boot: "start",
  shutdown: "stop",
  reboot: "restart",
  pause: "pause",
  resume: "resume",
  delete: "delete",
  // Resize is driven from the VM's settings form, not a lifecycle button.
  resize: null,
  // Sandbox-only kinds; VMs never carry them but the map stays total.
  snapshot: null,
  snapshot_delete: null,
  restore: null,
  // Sandbox-only, but the map stays total over OperationKind.
  snapshot_export: null,
  // Volume-only kinds (backend STR-148, STR-19); VMs never carry them, but
  // the map stays total.
  attach: null,
  detach: null,
  throttle: null,
  run: null,
};

export function VMActions({ vm, onActionComplete, allowedActions }: VMActionsProps) {
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const {
    isLoading: isSubmitting,
    busyKey: submittingAction,
    run,
  } = useAcceptedMutation();
  const pendingMutation = usePendingMutation(vm.id);
  const { permissions: queriedPermissions } = usePermissions(
    allowedActions ? [] : (["start", "stop", "restart", "pause", "resume", "delete"] as VMAction[]).map(
      (action) => ({
        key: action,
        action: `vm:${action}`,
        node: { type: "virtual_machine", id: vm.id },
      })
    )
  );
  const permissions = allowedActions ?? queriedPermissions;

  // Busy while the request is in flight OR while an accepted mutation is still
  // converging on the server — mutations no longer resolve synchronously.
  const isLoading = isSubmitting || !!pendingMutation;
  const activeAction =
    submittingAction ??
    (pendingMutation ? kindToAction[pendingMutation.kind] : null);

  const handleAction = (action: VMAction) =>
    // Each call returns 202; the MutationWatcher follows it to a terminal
    // state and toasts the outcome.
    run({
      busyKey: action,
      intentKey: JSON.stringify(["POST", `/api/vms/${vm.id}/${action}`, null]),
      request: (idempotencyKey) => vmsApi[action](vm.id, idempotencyKey),
      watch: {
        kind: actionToKind[action],
        resourceKind: "virtual_machine",
        resourceName: vm.name,
      },
      errorMessage: `Failed to ${action} VM`,
      onSuccess: () => {
        switch (action) {
          case "start":
            toast.success(`Starting ${vm.name}`);
            break;
          case "stop":
            toast.success(`Stopping ${vm.name}`);
            break;
          case "restart":
            toast.success(`Restarting ${vm.name}`);
            break;
          case "pause":
            toast.success(`Pausing ${vm.name}`);
            break;
          case "resume":
            toast.success(`Resuming ${vm.name}`);
            break;
          case "delete":
            setShowDeleteConfirm(false);
            toast.success(`Deleting ${vm.name}`);
            break;
        }
        onActionComplete?.();
      },
    });

  // Mirrors the backend's VM.canStart: `Error` is startable so an operator can
  // recover a VM whose state could not be confirmed (e.g. a lost start).
  const canStart =
    vm.status === "Shutdown" ||
    vm.status === "Created" ||
    vm.status === "Error";
  const canStop = vm.status === "Running" || vm.status === "Paused";
  const canPause = vm.status === "Running";
  const canResume = vm.status === "Paused";

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
          aria-label={`Start ${vm.name}`}
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
          aria-label={`Stop ${vm.name}`}
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
            aria-label={`More actions for ${vm.name}`}
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
            disabled={vm.status !== "Running"}
          >
            <RotateCcw className="h-4 w-4 mr-2 text-blue-600" />
            Restart
          </DropdownMenuItem>}
          {canPause && permissions.pause && (
            <DropdownMenuItem
              onClick={() => handleAction("pause")}
              className="text-foreground hover:bg-accent cursor-pointer"
            >
              <Pause className="h-4 w-4 mr-2 text-yellow-700" />
              Pause
            </DropdownMenuItem>
          )}
          {canResume && permissions.resume && (
            <DropdownMenuItem
              onClick={() => handleAction("resume")}
              className="text-foreground hover:bg-accent cursor-pointer"
            >
              <Play className="h-4 w-4 mr-2 text-green-600" />
              Resume
            </DropdownMenuItem>
          )}
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
            <DialogTitle>Delete {vm.name}?</DialogTitle>
            <DialogDescription className="text-muted-foreground">
              This will permanently delete the virtual machine and its disk.
              This action cannot be undone.
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
