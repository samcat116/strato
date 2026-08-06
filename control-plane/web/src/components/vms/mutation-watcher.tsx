"use client";

import { useEffect } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { operationsApi } from "@/lib/api/operations";
import { sandboxesApi } from "@/lib/api/sandboxes";
import { vmsApi } from "@/lib/api/vms";
import {
  useMutationsStore,
  type WatchedMutation,
} from "@/lib/stores/mutations-store";
import type { OperationKind, ResourceConditions } from "@/types/api";

const verbs: Record<OperationKind, { succeeded: string; infinitive: string }> = {
  create: { succeeded: "Created", infinitive: "create" },
  boot: { succeeded: "Started", infinitive: "start" },
  shutdown: { succeeded: "Stopped", infinitive: "stop" },
  reboot: { succeeded: "Restarted", infinitive: "restart" },
  pause: { succeeded: "Paused", infinitive: "pause" },
  resume: { succeeded: "Resumed", infinitive: "resume" },
  delete: { succeeded: "Deleted", infinitive: "delete" },
  resize: { succeeded: "Resized", infinitive: "resize" },
  snapshot: { succeeded: "Snapshotted", infinitive: "snapshot" },
  snapshot_delete: { succeeded: "Snapshot deleted", infinitive: "delete the snapshot of" },
  restore: { succeeded: "Restored", infinitive: "restore" },
  snapshot_export: { succeeded: "Snapshot exported", infinitive: "export the snapshot of" },
};

// The list query key to refresh when a mutation settles, so a create/delete/
// lifecycle change is reflected immediately.
const listQueryKey: Record<WatchedMutation["resourceKind"], string> = {
  virtual_machine: "vms",
  sandbox: "sandboxes",
};

type Outcome = { done: true; error?: string } | { done: false };

/**
 * Reads one refetched resource's conditions against the generation this
 * mutation is waiting on.
 *
 * `degraded` is compared by generation, not merely by presence: a failure can
 * stand against an older generation while a newer mutation is still in flight,
 * and reporting that as *this* mutation's failure would be wrong. Convergence
 * is `>=` for the same reason — a later mutation may already have moved the
 * target past ours, which still means ours was reached.
 */
function outcome(
  conditions: ResourceConditions,
  targetGeneration: number
): Outcome {
  if (conditions.degraded?.sinceGeneration === targetGeneration) {
    return { done: true, error: conditions.degraded.reason };
  }
  if (conditions.observedGeneration >= targetGeneration) {
    if (conditions.converged || conditions.targetGeneration > targetGeneration) {
      return { done: true };
    }
  }
  return { done: false };
}

/**
 * Follows every watched mutation to a terminal state, then toasts the outcome
 * and refreshes the relevant resource queries (VMs or sandboxes). Mounted once
 * in the dashboard layout so this survives navigation away from the page that
 * started the mutation.
 *
 * How an entry settles is on the entry itself (`source`), not inferred here —
 * see the mutations store for which mutations take which path.
 */
export function MutationWatcher() {
  const watched = useMutationsStore((state) => state.watched);
  const unwatch = useMutationsStore((state) => state.unwatch);
  const queryClient = useQueryClient();

  // Depend on the id set, not the record object, so the interval is not torn
  // down and re-created by unrelated store updates.
  const watchedIds = Object.keys(watched).sort().join(",");

  useEffect(() => {
    if (!watchedIds) return;

    let cancelled = false;

    const settle = async (entry: WatchedMutation): Promise<Outcome> => {
      if (entry.source === "operation") {
        const operation = await operationsApi.get(entry.mutationId);
        if (operation.status === "pending") return { done: false };
        return { done: true, error: operation.error ?? undefined };
      }
      const resource =
        entry.resourceKind === "virtual_machine"
          ? await vmsApi.get(entry.resourceId)
          : await sandboxesApi.get(entry.resourceId);
      return outcome(resource.conditions, entry.targetGeneration);
    };

    const poll = async () => {
      for (const id of watchedIds.split(",")) {
        // Re-read the store: another poll may have unwatched this id already.
        const entry = useMutationsStore.getState().watched[id];
        if (!entry) continue;

        try {
          const result = await settle(entry);
          if (cancelled || !result.done) continue;

          unwatch(id);
          queryClient.invalidateQueries({
            queryKey: [listQueryKey[entry.resourceKind]],
          });

          const verb = verbs[entry.kind];
          if (result.error) {
            toast.error(
              `Failed to ${verb.infinitive} ${entry.resourceName}: ${result.error}`
            );
          } else {
            toast.success(`${verb.succeeded} ${entry.resourceName}`);
          }
        } catch {
          // The resource or mutation became unreadable (e.g. the session
          // expired); stop watching rather than polling it forever.
          if (!cancelled) unwatch(id);
        }
      }
    };

    const interval = setInterval(poll, 2000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [watchedIds, unwatch, queryClient]);

  return null;
}
