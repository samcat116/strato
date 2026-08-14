"use client";

import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { useForceAgentOffline, usePermissions } from "@/lib/hooks";
import type { Agent } from "@/types/api";

export function AgentForceOfflineAction({ agent }: { agent: Agent }) {
  const [open, setOpen] = useState(false);
  const { permissions } = usePermissions([
    {
      key: "force_offline",
      action: "agent:manage",
      node: { type: "agent", id: agent.id },
    },
  ]);
  const forceOffline = useForceAgentOffline();

  if (!permissions.force_offline || !agent.isOnline) return null;

  return (
    <>
      <Button variant="destructive" onClick={() => setOpen(true)}>
        Force offline
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Force {agent.name} offline?</DialogTitle>
            <DialogDescription>
              Use this only when the agent is no longer reachable. Placements
              remain recorded and may need adoption before workloads can move.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)}>Cancel</Button>
            <Button
              variant="destructive"
              disabled={forceOffline.isPending}
              onClick={() =>
                forceOffline.mutate(agent.id, {
                  onSuccess: () => {
                    setOpen(false);
                    toast.success("Agent marked offline");
                  },
                  onError: (error) => toast.error(error.message),
                })
              }
            >
              Force offline
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
