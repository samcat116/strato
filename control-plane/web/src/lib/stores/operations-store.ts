// Client-side registry of in-flight resource operations (202 Accepted +
// polling). Shared across VMs and sandboxes: both return an Operation on
// mutation and both are polled to a terminal state by the same OperationWatcher.
//
// Components that fire a mutation `watch()` the returned operation; the
// globally-mounted OperationWatcher polls each one to a terminal state and
// then removes it. Everything held here is pending by construction.

import { create } from "zustand";
import type { Operation } from "@/types/api";

export interface WatchedOperation {
  operation: Operation;
  /** Captured at watch time so terminal toasts can name the resource even after it is deleted. */
  resourceName: string;
}

interface OperationsState {
  watched: Record<string, WatchedOperation>;
  watch: (operation: Operation, resourceName: string) => void;
  unwatch: (operationId: string) => void;
}

export const useOperationsStore = create<OperationsState>((set) => ({
  watched: {},
  watch: (operation, resourceName) =>
    set((state) => ({
      watched: {
        ...state.watched,
        [operation.id]: { operation, resourceName },
      },
    })),
  unwatch: (operationId) =>
    set((state) => {
      const watched = { ...state.watched };
      delete watched[operationId];
      return { watched };
    }),
}));

/**
 * The watched in-flight operation targeting a resource (VM or sandbox), if any.
 * Matches on `resourceId`, which the backend populates for both resource kinds.
 */
export function usePendingOperation(
  resourceId: string | undefined
): Operation | undefined {
  return useOperationsStore((state) =>
    resourceId
      ? Object.values(state.watched).find(
          (w) => w.operation.resourceId === resourceId
        )?.operation
      : undefined
  );
}
