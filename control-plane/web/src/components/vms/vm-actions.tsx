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
import { friendlyErrorMessage } from "@/lib/errors";
import {
  usePendingOperation,
  useOperationsStore,
} from "@/lib/stores/operations-store";
import { toast } from "sonner";
import type { VM, OperationKind } from "@/types/api";

interface VMActionsProps {
  vm: VM;
  onActionComplete?: () => void;
}

type VMAction = "start" | "stop" | "restart" | "pause" | "resume" | "delete";

// Maps an in-flight operation (which may have been started elsewhere, e.g. on
// the detail page) back to the action button that should show the spinner.
const kindToAction: Record<OperationKind, VMAction | null> = {
  create: null,
  boot: "start",
  shutdown: "stop",
  reboot: "restart",
  pause: "pause",
  resume: "resume",
  delete: "delete",
  // Sandbox-only kinds; VMs never carry them but the map stays total.
  snapshot: null,
  snapshot_delete: null,
  restore: null,
};

export function VMActions({ vm, onActionComplete }: VMActionsProps) {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [submittingAction, setSubmittingAction] = useState<string | null>(null);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const watch = useOperationsStore((state) => state.watch);
  const pendingOperation = usePendingOperation(vm.id);

  // Busy while the request is in flight OR while an accepted operation is still
  // pending on the server — mutations no longer resolve synchronously.
  const isLoading = isSubmitting || !!pendingOperation;
  const activeAction =
    submittingAction ??
    (pendingOperation ? kindToAction[pendingOperation.kind] : null);

  const handleAction = async (action: VMAction) => {
    setIsSubmitting(true);
    setSubmittingAction(action);

    try {
      // Each call returns 202 with an operation record; the OperationWatcher
      // polls it to a terminal state and toasts the outcome.
      const operation = await vmsApi[action](vm.id);
      watch(operation, vm.name);

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
    } catch (error) {
      toast.error(friendlyErrorMessage(error, `Failed to ${action} VM`));
    } finally {
      setIsSubmitting(false);
      setSubmittingAction(null);
    }
  };

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
            disabled={vm.status !== "Running"}
          >
            <RotateCcw className="h-4 w-4 mr-2 text-blue-600" />
            Restart
          </DropdownMenuItem>
          {canPause && (
            <DropdownMenuItem
              onClick={() => handleAction("pause")}
              className="text-foreground hover:bg-accent cursor-pointer"
            >
              <Pause className="h-4 w-4 mr-2 text-yellow-700" />
              Pause
            </DropdownMenuItem>
          )}
          {canResume && (
            <DropdownMenuItem
              onClick={() => handleAction("resume")}
              className="text-foreground hover:bg-accent cursor-pointer"
            >
              <Play className="h-4 w-4 mr-2 text-green-600" />
              Resume
            </DropdownMenuItem>
          )}
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
