"use client";

import { useEffect } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { operationsApi } from "@/lib/api/operations";
import { useOperationsStore } from "@/lib/stores/operations-store";
import type { OperationKind } from "@/types/api";

const verbs: Record<OperationKind, { succeeded: string; infinitive: string }> = {
  create: { succeeded: "Created", infinitive: "create" },
  boot: { succeeded: "Started", infinitive: "start" },
  shutdown: { succeeded: "Stopped", infinitive: "stop" },
  reboot: { succeeded: "Restarted", infinitive: "restart" },
  pause: { succeeded: "Paused", infinitive: "pause" },
  resume: { succeeded: "Resumed", infinitive: "resume" },
  delete: { succeeded: "Deleted", infinitive: "delete" },
};

/**
 * Polls every watched operation until it reaches a terminal state, then toasts
 * the outcome and refreshes the VM queries. Mounted once in the dashboard
 * layout so polling survives navigation away from the page that started the
 * operation.
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
          queryClient.invalidateQueries({ queryKey: ["vms"] });

          const verb = verbs[operation.kind];
          if (operation.status === "succeeded") {
            toast.success(`${verb.succeeded} ${entry.vmName}`);
          } else {
            toast.error(
              `Failed to ${verb.infinitive} ${entry.vmName}: ${
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
