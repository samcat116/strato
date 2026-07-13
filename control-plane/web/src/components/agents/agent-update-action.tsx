"use client";

import { useState } from "react";
import { ArrowUpCircle, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { toast } from "sonner";
import { useUpdateAgent } from "@/lib/hooks";
import { ApiError } from "@/lib/api/client";
import type { Agent } from "@/types/api";

interface AgentUpdateActionProps {
  agent: Agent;
  size?: "sm" | "default";
}

/**
 * "Update" button shown when an online agent runs a version older than the
 * deployment's target. Confirms the restart caveats, then triggers the
 * control-plane-driven self-update; the request resolves only once the agent
 * has installed the binary and started restarting.
 *
 * A 409 from the endpoint is a refusal the operator may override (hosted
 * sandboxes, already at target): the dialog surfaces the reason and
 * offers a force retry instead of failing outright.
 */
export function AgentUpdateAction({ agent, size = "default" }: AgentUpdateActionProps) {
  const [open, setOpen] = useState(false);
  const [conflict, setConflict] = useState<string | null>(null);
  const updateAgent = useUpdateAgent();

  if (!agent.updateAvailable || !agent.isOnline) {
    return null;
  }

  const closeDialog = () => {
    setOpen(false);
    setConflict(null);
  };

  const handleUpdate = async (force: boolean) => {
    try {
      const result = await updateAgent.mutateAsync({ id: agent.id, force });
      closeDialog();
      toast.success(
        result.message ?? `Agent is updating to ${result.targetVersion} and restarting`
      );
    } catch (error) {
      if (error instanceof ApiError && error.status === 409) {
        // Refused with a reason the operator may override — offer force.
        setConflict(error.message);
      } else {
        closeDialog();
        toast.error(error instanceof Error ? error.message : "Failed to update agent");
      }
    }
  };

  return (
    <>
      <Button
        variant="outline"
        size={size}
        className="border-amber-500/50 text-amber-600 dark:text-amber-400 hover:bg-amber-500/10"
        onClick={() => setOpen(true)}
      >
        <ArrowUpCircle className="h-4 w-4 mr-1.5" />
        Update
      </Button>

      <Dialog open={open} onOpenChange={(next) => (next ? setOpen(true) : closeDialog())}>
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>
              Update {agent.name}
              {agent.targetVersion ? ` to ${agent.targetVersion}` : ""}?
            </DialogTitle>
            <DialogDescription className="text-muted-foreground" asChild>
              <div className="space-y-2">
                <p>
                  The agent downloads the new binary, verifies its checksum, and restarts
                  into it. During the restart:
                </p>
                <ul className="list-disc pl-5 space-y-1">
                  <li>The agent briefly disconnects; it re-registers automatically.</li>
                  <li>
                    Running VMs (QEMU and Firecracker) keep running and are re-adopted
                    afterwards.
                  </li>
                  <li>
                    Running sandboxes are <span className="font-medium">not</span> yet
                    re-adopted — they keep running but can only be deleted afterwards.
                  </li>
                </ul>
                <p>
                  If the update fails verification, the current binary stays in place. The
                  replaced binary is kept next to it as <code>.prev</code> for manual
                  rollback.
                </p>
              </div>
            </DialogDescription>
          </DialogHeader>
          {conflict && (
            <p className="text-sm text-amber-600 dark:text-amber-400">
              {conflict}
            </p>
          )}
          {updateAgent.isPending && (
            <p className="text-sm text-muted-foreground">
              The agent is downloading and verifying the update — this can take a few
              minutes…
            </p>
          )}
          <DialogFooter>
            <Button
              variant="outline"
              className="border-input"
              onClick={closeDialog}
              disabled={updateAgent.isPending}
            >
              Cancel
            </Button>
            <Button
              onClick={() => handleUpdate(conflict !== null)}
              disabled={updateAgent.isPending}
            >
              {updateAgent.isPending ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <ArrowUpCircle className="h-4 w-4" />
              )}
              {conflict ? "Force update" : "Update"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
