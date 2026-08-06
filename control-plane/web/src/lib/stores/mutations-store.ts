// Client-side registry of in-flight resource mutations. Shared across VMs and
// sandboxes: components that fire a mutation `watch()` what came back, and the
// globally mounted MutationWatcher follows each entry to a terminal state and
// removes it. Everything held here is in flight by construction.
//
// Two things end up here, because the backend answers two ways (STR-147):
//
// * **Generation-backed lifecycle mutations** — 202 with `{resource,
//   targetGeneration, mutationId}`. Followed by refetching the resource and
//   reading its `conditions`. No operation object exists.
// * **Imperative verbs** — VM restart and every snapshot verb, which still
//   answer with an `Operation` record, plus **deletes**, whose success is the
//   resource ceasing to exist and so cannot be read off it. Followed by
//   polling the operations endpoint.
//
// `source` is what tells them apart, so the watcher never has to guess from
// the verb.

import { create } from "zustand";
import type {
  AcceptedMutation,
  Operation,
  OperationKind,
  OperationResourceKind,
} from "@/types/api";

export interface WatchedMutation {
  /**
   * What identifies this mutation to the server: a `resource_events` id for a
   * lifecycle mutation, an operation row's id for an imperative one. Both are
   * what `GET /api/operations/{id}` answers for.
   */
  mutationId: string;
  /** Where the terminal answer comes from. */
  source: "conditions" | "operation";
  resourceKind: OperationResourceKind;
  resourceId: string;
  /** The generation `conditions.observedGeneration` must reach; 0 when unused. */
  targetGeneration: number;
  /** Drives the terminal toast's verb, and the spinner on the matching button. */
  kind: OperationKind;
  /** Captured at watch time so terminal toasts can name a resource that is now deleted. */
  resourceName: string;
}

interface MutationsState {
  watched: Record<string, WatchedMutation>;
  watch: (mutation: WatchedMutation) => void;
  unwatch: (mutationId: string) => void;
}

export const useMutationsStore = create<MutationsState>((set) => ({
  watched: {},
  watch: (mutation) =>
    set((state) => ({
      watched: { ...state.watched, [mutation.mutationId]: mutation },
    })),
  unwatch: (mutationId) =>
    set((state) => {
      const watched = { ...state.watched };
      delete watched[mutationId];
      return { watched };
    }),
}));

/**
 * A watchable entry from a lifecycle mutation's 202.
 *
 * A delete is followed through the operations endpoint even though it is
 * generation-backed: once its row is gone there is nothing to refetch, and a
 * 404 on the resource means deleted, never-existed and not-authorized alike.
 */
export function acceptedMutation(
  accepted: AcceptedMutation<{ id: string }>,
  options: {
    kind: OperationKind;
    resourceKind: OperationResourceKind;
    resourceName: string;
  }
): WatchedMutation {
  return {
    mutationId: accepted.mutationId,
    source: options.kind === "delete" ? "operation" : "conditions",
    resourceKind: options.resourceKind,
    resourceId: accepted.resource.id,
    targetGeneration: accepted.targetGeneration,
    kind: options.kind,
    resourceName: options.resourceName,
  };
}

/** A watchable entry from a verb that still answers with an operation record. */
export function acceptedOperation(
  operation: Operation,
  resourceName: string
): WatchedMutation {
  return {
    mutationId: operation.id,
    source: "operation",
    resourceKind: operation.resourceKind,
    resourceId: operation.resourceId,
    targetGeneration: 0,
    kind: operation.kind,
    resourceName,
  };
}

/** The watched in-flight mutation targeting a resource (VM or sandbox), if any. */
export function usePendingMutation(
  resourceId: string | undefined
): WatchedMutation | undefined {
  return useMutationsStore((state) =>
    resourceId
      ? Object.values(state.watched).find((m) => m.resourceId === resourceId)
      : undefined
  );
}
