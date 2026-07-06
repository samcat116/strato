// Client-side registry of in-flight VM operations (202 Accepted + polling).
//
// Components that fire a mutation `watch()` the returned operation; the
// globally-mounted OperationWatcher polls each one to a terminal state and
// then removes it. Everything held here is pending by construction.

import { create } from "zustand";
import type { Operation } from "@/types/api";

export interface WatchedOperation {
  operation: Operation;
  /** Captured at watch time so terminal toasts can name the VM even after it is deleted. */
  vmName: string;
}

interface OperationsState {
  watched: Record<string, WatchedOperation>;
  watch: (operation: Operation, vmName: string) => void;
  unwatch: (operationId: string) => void;
}

export const useOperationsStore = create<OperationsState>((set) => ({
  watched: {},
  watch: (operation, vmName) =>
    set((state) => ({
      watched: { ...state.watched, [operation.id]: { operation, vmName } },
    })),
  unwatch: (operationId) =>
    set((state) => {
      const watched = { ...state.watched };
      delete watched[operationId];
      return { watched };
    }),
}));

/** The watched in-flight operation targeting a VM, if any. */
export function usePendingOperation(
  vmId: string | undefined
): Operation | undefined {
  return useOperationsStore((state) =>
    vmId
      ? Object.values(state.watched).find((w) => w.operation.vmId === vmId)
          ?.operation
      : undefined
  );
}
