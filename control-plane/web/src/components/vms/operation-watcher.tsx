"use client";

import { useEffect } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { operationsApi } from "@/lib/api/operations";
import { useOperationsStore } from "@/lib/stores/operations-store";
import type { Operation, OperationKind } from "@/types/api";

const verbs: Record<OperationKind, { succeeded: string; infinitive: string }> = {
  create: { succeeded: "Created", infinitive: "create" },
  boot: { succeeded: "Started", infinitive: "start" },
  shutdown: { succeeded: "Stopped", infinitive: "stop" },
  reboot: { succeeded: "Restarted", infinitive: "restart" },
  pause: { succeeded: "Paused", infinitive: "pause" },
  resume: { succeeded: "Resumed", infinitive: "resume" },
  delete: { succeeded: "Deleted", infinitive: "delete" },
  snapshot: { succeeded: "Snapshotted", infinitive: "snapshot" },
  snapshot_delete: { succeeded: "Snapshot deleted", infinitive: "delete the snapshot of" },
  restore: { succeeded: "Restored", infinitive: "restore" },
};

// The list query key to refresh when an operation of a given resource kind
// completes, so a create/delete/lifecycle change is reflected immediately.
const listQueryKey: Record<Operation["resourceKind"], string> = {
  virtual_machine: "vms",
  sandbox: "sandboxes",
};

/**
 * Polls every watched operation until it reaches a terminal state, then toasts
 * the outcome and refreshes the relevant resource queries (VMs or sandboxes).
 * Mounted once in the dashboard layout so polling survives navigation away from
 * the page that started the operation.
 */
export function OperationWatcher() {
  const watched = useOperationsStore((state) => state.watched);
  const unwatch = useOperationsStore((state) => state.unwatch);
  const queryClient = useQueryClient();

  // Depend on the id set, not the record object, so the interval is not torn
  // down and re-created by unrelated store updates.
  const watchedIds = Object.keys(watched).sort().join(",");

  useEffect(() => {
    if (!watchedIds) return;

    let cancelled = false;

    const poll = async () => {
      for (const id of watchedIds.split(",")) {
        // Re-read the store: another poll may have unwatched this id already.
        const entry = useOperationsStore.getState().watched[id];
        if (!entry) continue;

        try {
          const operation = await operationsApi.get(id);
          if (cancelled || operation.status === "pending") continue;

          unwatch(id);
          queryClient.invalidateQueries({
            queryKey: [listQueryKey[operation.resourceKind]],
          });

          const verb = verbs[operation.kind];
          if (operation.status === "succeeded") {
            toast.success(`${verb.succeeded} ${entry.resourceName}`);
          } else {
            toast.error(
              `Failed to ${verb.infinitive} ${entry.resourceName}: ${
                operation.error ?? "unknown error"
              }`
            );
          }
        } catch {
          // The operation became unreadable (e.g. session expired or it was
          // pruned); stop watching rather than polling it forever.
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
