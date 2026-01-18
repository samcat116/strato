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
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { vmsApi } from "@/lib/api/vms";
import { toast } from "sonner";
import type { VM } from "@/types/api";

interface VMActionsProps {
  vm: VM;
  onActionComplete?: () => void;
}

export function VMActions({ vm, onActionComplete }: VMActionsProps) {
  const [isLoading, setIsLoading] = useState(false);
  const [activeAction, setActiveAction] = useState<string | null>(null);

  const handleAction = async (
    action: "start" | "stop" | "restart" | "pause" | "resume" | "delete"
  ) => {
    setIsLoading(true);
    setActiveAction(action);

    try {
      switch (action) {
        case "start":
          await vmsApi.start(vm.id);
          toast.success(`Starting ${vm.name}`);
          break;
        case "stop":
          await vmsApi.stop(vm.id);
          toast.success(`Stopping ${vm.name}`);
          break;
        case "restart":
          await vmsApi.restart(vm.id);
          toast.success(`Restarting ${vm.name}`);
          break;
        case "pause":
          await vmsApi.pause(vm.id);
          toast.success(`Pausing ${vm.name}`);
          break;
        case "resume":
          await vmsApi.resume(vm.id);
          toast.success(`Resuming ${vm.name}`);
          break;
        case "delete":
          await vmsApi.delete(vm.id);
          toast.success(`Deleted ${vm.name}`);
          break;
      }
      onActionComplete?.();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : `Failed to ${action} VM`
      );
    } finally {
      setIsLoading(false);
      setActiveAction(null);
    }
  };

  const canStart = vm.status === "Shutdown" || vm.status === "Created";
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
            onClick={() => handleAction("delete")}
            className="text-red-400 hover:bg-red-500/10 cursor-pointer"
          >
            <Trash2 className="h-4 w-4 mr-2" />
            Delete
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  );
}
