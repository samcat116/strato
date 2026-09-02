"use client";

import { formatDateTime } from "@/lib/format-time";

import { errorMessage } from "@/lib/errors";

import { useState } from "react";
import { AlertTriangle, Loader2, ShieldAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { toast } from "sonner";
import { useAdoptAgentWorkloads } from "@/lib/hooks";
import type { Agent } from "@/types/api";

interface AgentWorkloadSafetyCardProps {
  agent: Agent;
}

/**
 * Workload-safety state for one agent (STR-98).
 *
 * Two things surface here, both of which mean the control plane and the host
 * disagree about what should be running:
 *
 * - **Held workloads.** The agent is running something no desired-state sync
 *   mentions. It keeps running it and reports it instead of tearing it down,
 *   and the control plane refuses to authorize a teardown while a record still
 *   exists. When the record sits on a *different* agent record, the node was
 *   re-enrolled (a corrected name, or a move to its organization's trust
 *   domain) and its workloads can be adopted onto this one.
 * - **A refused teardown.** The agent declined to converge a batch of
 *   authorized teardowns because it would have emptied too much of the host at
 *   once.
 * - **An unreadable workload manifest** (STR-138). The manifest is the agent's
 *   only memory of what it is running, so a host that cannot read it does not
 *   know its own contents. It quarantines itself — no advertised capacity,
 *   nothing converged — until an operator repairs the file on the node. This
 *   one is the most urgent of the three: nothing on that host is being managed.
 *
 * The card renders nothing when none applies, which is the normal case.
 */
export function AgentWorkloadSafetyCard({ agent }: AgentWorkloadSafetyCardProps) {
  const adopt = useAdoptAgentWorkloads();
  const [adopting, setAdopting] = useState<string | null>(null);

  const held = agent.heldWorkloads ?? [];
  // `manifestInventoryComplete === false` is the blind host; a reason with the
  // flag true (or absent) is the milder "some entries can't be routed".
  const blind = agent.manifestInventoryComplete === false;
  if (held.length === 0 && !agent.teardownRefusalReason && !agent.manifestStatusReason) {
    return null;
  }

  // Held workloads whose records sit on another agent record, grouped by it:
  // each group is one re-enrollment an operator can finish.
  const bySourceAgent = new Map<string, number>();
  for (const workload of held) {
    if (!workload.placedOnAgentId) continue;
    bySourceAgent.set(
      workload.placedOnAgentId,
      (bySourceAgent.get(workload.placedOnAgentId) ?? 0) + 1
    );
  }
  const strandedHere = held.filter((workload) => !workload.placedOnAgentId).length;

  const runAdoption = async (fromAgentId: string) => {
    setAdopting(fromAgentId);
    try {
      const result = await adopt.mutateAsync({ id: agent.id, fromAgentId });
      toast.success(
        `Adopted ${result.adoptedVMs} VM(s), ${result.adoptedSandboxes} sandbox(es), ` +
          `and ${result.adoptedVolumes} volume(s) onto ${agent.name}`
      );
    } catch (error) {
      toast.error(errorMessage(error, "Failed to adopt workloads"));
    } finally {
      setAdopting(null);
    }
  };

  return (
    <Card className="bg-card border-border">
      <CardHeader className="pb-3">
        <CardTitle className="text-lg font-semibold text-foreground flex items-center gap-2">
          <ShieldAlert className="h-5 w-5" />
          Workload safety
          <Badge variant="secondary" className="bg-amber-600 text-white">
            Attention
          </Badge>
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-4 text-sm">
        {agent.manifestStatusReason && (
          <div
            className={
              blind
                ? "flex items-start gap-2 text-red-600 dark:text-red-400"
                : "flex items-start gap-2 text-amber-600 dark:text-amber-400"
            }
          >
            <AlertTriangle className="h-4 w-4 mt-0.5 shrink-0" />
            <p>
              {blind
                ? "This node cannot read its workload manifest, so it does not know what it is running. It is advertising no capacity and converging nothing: "
                : "Workload manifest: "}
              {agent.manifestStatusReason}
              {agent.manifestStatusAt
                ? ` (reported ${formatDateTime(agent.manifestStatusAt)})`
                : ""}
            </p>
          </div>
        )}

        {agent.teardownRefusalReason && (
          <div className="flex items-start gap-2 text-red-600 dark:text-red-400">
            <AlertTriangle className="h-4 w-4 mt-0.5 shrink-0" />
            <p>
              Teardown refused: {agent.teardownRefusalReason}
              {agent.teardownRefusedAt
                ? ` (last refused ${formatDateTime(agent.teardownRefusedAt)})`
                : ""}
            </p>
          </div>
        )}

        {held.length > 0 && (
          <div className="space-y-3">
            <p className="text-muted-foreground">
              This node is running {held.length} workload(s) that its desired state does
              not describe. They are left running: nothing is torn down because the
              control plane failed to mention it.
            </p>

            {[...bySourceAgent.entries()].map(([sourceAgentId, count]) => (
              <div
                key={sourceAgentId}
                className="flex items-start justify-between gap-3 rounded-md border border-border p-3"
              >
                <div>
                  <p className="text-foreground">
                    {count} workload(s) still assigned to agent record{" "}
                    <span className="font-mono text-xs">{sourceAgentId}</span>
                  </p>
                  <p className="text-muted-foreground">
                    This node most likely re-enrolled under a new record. Adopting moves
                    those workloads — and their volumes — onto this agent.
                  </p>
                </div>
                <Button
                  variant="outline"
                  size="sm"
                  className="border-input shrink-0"
                  onClick={() => runAdoption(sourceAgentId)}
                  // Only the row being adopted is disabled: with two source
                  // records listed, a global disable makes clicking one look
                  // like it disabled the other.
                  disabled={adopting === sourceAgentId}
                >
                  {adopting === sourceAgentId && (
                    <Loader2 className="h-4 w-4 mr-1.5 animate-spin" />
                  )}
                  Adopt workloads
                </Button>
              </div>
            ))}

            {strandedHere > 0 && (
              <p className="text-amber-600 dark:text-amber-400">
                {strandedHere} of them are already assigned to this agent, which means a
                sync omitted workloads it owns. That is a control-plane bug — check the
                control-plane logs for withheld teardowns before changing anything here.
              </p>
            )}
          </div>
        )}
      </CardContent>
    </Card>
  );
}
