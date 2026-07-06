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
          className="text-green-400 hover:text-green-300 hover:bg-green-500/10"
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
          className="text-red-400 hover:text-red-300 hover:bg-red-500/10"
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
            className="text-gray-400 hover:text-gray-200"
            disabled={isLoading}
          >
            <MoreHorizontal className="h-4 w-4" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent className="bg-gray-800 border-gray-700">
          {canStart && (
            <DropdownMenuItem
              onClick={() => handleAction("start")}
              className="text-gray-200 hover:bg-gray-700 cursor-pointer"
            >
              <Play className="h-4 w-4 mr-2 text-green-400" />
              Start
            </DropdownMenuItem>
          )}
          {canStop && (
            <DropdownMenuItem
              onClick={() => handleAction("stop")}
              className="text-gray-200 hover:bg-gray-700 cursor-pointer"
            >
              <Square className="h-4 w-4 mr-2 text-red-400" />
              Stop
            </DropdownMenuItem>
          )}
          <DropdownMenuItem
            onClick={() => handleAction("restart")}
            className="text-gray-200 hover:bg-gray-700 cursor-pointer"
            disabled={vm.status !== "Running"}
          >
            <RotateCcw className="h-4 w-4 mr-2 text-blue-400" />
            Restart
          </DropdownMenuItem>
          {canPause && (
            <DropdownMenuItem
              onClick={() => handleAction("pause")}
              className="text-gray-200 hover:bg-gray-700 cursor-pointer"
            >
              <Pause className="h-4 w-4 mr-2 text-yellow-400" />
              Pause
            </DropdownMenuItem>
          )}
          {canResume && (
            <DropdownMenuItem
              onClick={() => handleAction("resume")}
              className="text-gray-200 hover:bg-gray-700 cursor-pointer"
            >
              <Play className="h-4 w-4 mr-2 text-green-400" />
              Resume
            </DropdownMenuItem>
          )}
          <DropdownMenuSeparator className="bg-gray-700" />
          <DropdownMenuItem
            onClick={() => setShowDeleteConfirm(true)}
            className="text-red-400 hover:bg-red-500/10 cursor-pointer"
          >
            <Trash2 className="h-4 w-4 mr-2" />
            Delete
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>

      {/* Delete confirmation dialog */}
      <Dialog open={showDeleteConfirm} onOpenChange={setShowDeleteConfirm}>
        <DialogContent className="bg-gray-800 border-gray-700 text-gray-100">
          <DialogHeader>
            <DialogTitle>Delete {vm.name}?</DialogTitle>
            <DialogDescription className="text-gray-400">
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
