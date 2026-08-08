// Client-side registry of in-flight resource mutations. Shared across VMs and
// sandboxes: components that fire a mutation `watch()` what came back, and the
// globally mounted MutationWatcher follows each entry to a terminal state and
// removes it. Everything held here is in flight by construction.
//
// Every mutation answers the same way now (STR-147, and STR-151 for the last
// three verbs): 202 with `{resource, targetGeneration, mutationId}`, followed by
// refetching the resource and reading its `conditions`. What still differs is
// where the *terminal answer* comes from:
//
// * most mutations — the resource's own `conditions`;
// * **deletes** — the operations endpoint, because success is the resource
//   ceasing to exist and so cannot be read off it.
//
// Snapshot artifacts became generation-backed resources in ADR 0001 stage 8,
// but they are watched through the operations endpoint anyway: there is no
// single-snapshot GET to refetch, and the operations façade already answers
// for every kind from the artifact's own conditions.
//
// `source` is what tells them apart, so the watcher never has to guess from
// the verb.

import { create } from "zustand";
import type {
  AcceptedMutation,
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
  accepted: AcceptedMutation<{ id?: string }>,
  options: {
    kind: OperationKind;
    resourceKind: OperationResourceKind;
    resourceName: string;
    /**
     * The resource's id, for DTOs that type it as optional — `Volume` does,
     * because the backend's model id is nullable until the row is inserted.
     * Callers that have the id in hand should pass it; the fallback exists for
     * the VM and sandbox DTOs, which type it as required.
     */
    resourceId?: string;
  }
): WatchedMutation {
  return {
    mutationId: accepted.mutationId,
    source: options.kind === "delete" ? "operation" : "conditions",
    resourceKind: options.resourceKind,
    resourceId: options.resourceId ?? accepted.resource.id!,
    targetGeneration: accepted.targetGeneration,
    kind: options.kind,
    resourceName: options.resourceName,
  };
}

/**
 * A watchable entry from a snapshot mutation's 202 (STR-150).
 *
 * Followed through the operations façade rather than by refetching the
 * artifact: snapshots are listed under their parent and have no
 * single-resource GET, and the façade answers for a snapshot id from exactly
 * the conditions a refetch would have read.
 */
export function acceptedSnapshotMutation(
  accepted: AcceptedMutation<{ id?: string }>,
  options: {
    kind: OperationKind;
    resourceKind: OperationResourceKind;
    resourceName: string;
  }
): WatchedMutation {
  return {
    mutationId: accepted.mutationId,
    source: "operation",
    resourceKind: options.resourceKind,
    resourceId: accepted.resource.id!,
    targetGeneration: accepted.targetGeneration,
    kind: options.kind,
    resourceName: options.resourceName,
  };
}

// `acceptedOperation` — the adapter for a verb that answered with an operation
// record rather than its resource — went with the last such verb: VM restart and
// the two restores became generation-backed in backend STR-151. Every mutation
// now answers with `{resource, targetGeneration, mutationId}`.

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
