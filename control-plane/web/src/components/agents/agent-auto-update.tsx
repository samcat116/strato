"use client";

import { Loader2, RefreshCw, AlertTriangle, PauseCircle } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { toast } from "sonner";
import { usePatchAgent } from "@/lib/hooks";
import type { Agent } from "@/types/api";

interface AgentAutoUpdateCardProps {
  agent: Agent;
}

/**
 * Auto-update enrollment and rollout status (issue #434). Enrolled agents are
 * updated by the control plane one at a time: the fleet rollout assigns the
 * target version, the agent converges when its own preconditions allow (no
 * running Firecracker VMs, no in-flight work, not containerized), and the
 * next agent follows only once this one re-registers healthy.
 */
export function AgentAutoUpdateCard({ agent }: AgentAutoUpdateCardProps) {
  const patchAgent = usePatchAgent();

  const toggle = async (autoUpdate: boolean) => {
    try {
      await patchAgent.mutateAsync({ id: agent.id, autoUpdate });
      toast.success(
        autoUpdate
          ? `${agent.name} enrolled in auto-update`
          : `${agent.name} withdrawn from auto-update`
      );
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Failed to update agent");
    }
  };

  return (
    <Card className="bg-card border-border">
      <CardHeader className="pb-3">
        <div className="flex items-center justify-between">
          <CardTitle className="text-lg font-semibold text-foreground flex items-center gap-2">
            <RefreshCw className="h-5 w-5" />
            Auto-update
            {agent.autoUpdate ? (
              <Badge className="bg-green-600">Enabled</Badge>
            ) : (
              <Badge variant="secondary" className="bg-muted">
                Disabled
              </Badge>
            )}
          </CardTitle>
          <Button
            variant="outline"
            size="sm"
            className="border-input"
            onClick={() => toggle(!agent.autoUpdate)}
            disabled={patchAgent.isPending}
          >
            {patchAgent.isPending && <Loader2 className="h-4 w-4 mr-1.5 animate-spin" />}
            {agent.autoUpdate ? "Disable" : "Enable"}
          </Button>
        </div>
      </CardHeader>
      <CardContent className="space-y-3 text-sm">
        <p className="text-muted-foreground">
          Enrolled agents are updated to the deployment&apos;s target version by the
          control plane, one agent at a time, each waiting for the previous one to
          re-register healthy. The agent only restarts itself when nothing would be
          lost: containerized installs, running Firecracker workloads, and in-flight
          operations all defer the update.
        </p>

        {agent.autoUpdate && agent.updateDesiredVersion && (
          <div className="flex items-start gap-2 text-foreground">
            <Loader2 className="h-4 w-4 mt-0.5 animate-spin text-muted-foreground" />
            <p>
              Updating to <span className="font-medium">{agent.updateDesiredVersion}</span>
              {agent.updateAttemptedAt
                ? ` (assigned ${new Date(agent.updateAttemptedAt).toLocaleString()})`
                : " (waiting on the agent)"}
            </p>
          </div>
        )}

        {agent.updateBlockedReason && (
          <div className="flex items-start gap-2 text-amber-600 dark:text-amber-400">
            <PauseCircle className="h-4 w-4 mt-0.5" />
            <p>Blocked: {agent.updateBlockedReason}</p>
          </div>
        )}

        {agent.updateFailureReason && (
          <div className="flex items-start gap-2 text-red-600 dark:text-red-400">
            <AlertTriangle className="h-4 w-4 mt-0.5" />
            <p>
              Update failed (rollout halted here): {agent.updateFailureReason}. Re-enable
              auto-update to retry, or update manually.
            </p>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
