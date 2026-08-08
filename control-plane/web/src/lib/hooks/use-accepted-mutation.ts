import { useState } from "react";
import { toast } from "sonner";
import { friendlyErrorMessage } from "@/lib/errors";
import {
  acceptedMutation,
  acceptedSnapshotMutation,
  useMutationsStore,
} from "@/lib/stores/mutations-store";
import type {
  AcceptedMutation,
  OperationKind,
  OperationResourceKind,
} from "@/types/api";

/** What MutationWatcher should record about an accepted 202. */
export interface AcceptedMutationWatch {
  kind: OperationKind;
  resourceKind: OperationResourceKind;
  resourceName: string;
  /**
   * The resource's id, for DTOs that type it as optional (`Volume` does);
   * defaults to the id on the 202's resource.
   */
  resourceId?: string;
  /**
   * Watch through the operations façade (`acceptedSnapshotMutation`, backend
   * STR-150) rather than by refetching the resource — for snapshot artifacts,
   * which are listed under their parent and have no single-resource GET.
   */
  snapshot?: boolean;
}

export interface RunAcceptedMutationOptions<Resource extends { id?: string }> {
  /** The 202-returning API call. */
  request: () => Promise<AcceptedMutation<Resource>>;
  /** The entry MutationWatcher follows to a terminal state. */
  watch: AcceptedMutationWatch;
  /** Fallback error-toast text, for failures that carry no message. */
  errorMessage: string;
  /** Optional success toast, shown before `onSuccess` runs. */
  successMessage?: string;
  /** Site-specific post-success behavior: closing dialogs, resetting forms, extra invalidations. */
  onSuccess?: (accepted: AcceptedMutation<Resource>) => void;
  /**
   * Intercepts a failure before the toast. Return true to mark it handled
   * (e.g. rendered inline) and suppress the default error toast.
   */
  onError?: (message: string) => boolean;
  /**
   * Names which button or row is busy while the request is in flight,
   * surfaced as `busyKey` — for components that spin one row of many.
   */
  busyKey?: string;
}

/**
 * The shared accepted-mutation flow (backend STR-147): fire a lifecycle call
 * that answers 202, hand the result to MutationWatcher — which follows it to a
 * terminal state and toasts the outcome — and absorb the busy-state
 * bookkeeping and error toast that every call site used to hand-roll. The
 * request itself only says the mutation was recorded; the terminal toast
 * always comes from the watcher.
 *
 * Errors go through `friendlyErrorMessage`, so known backend strings surface
 * as actionable text instead of raw internals.
 */
export function useAcceptedMutation() {
  const watch = useMutationsStore((state) => state.watch);
  const [isLoading, setIsLoading] = useState(false);
  const [busyKey, setBusyKey] = useState<string | null>(null);

  async function run<Resource extends { id?: string }>(
    options: RunAcceptedMutationOptions<Resource>
  ): Promise<void> {
    setIsLoading(true);
    setBusyKey(options.busyKey ?? null);
    try {
      const accepted = await options.request();
      const { snapshot, ...watchOptions } = options.watch;
      watch(
        snapshot
          ? acceptedSnapshotMutation(accepted, watchOptions)
          : acceptedMutation(accepted, watchOptions)
      );
      if (options.successMessage) {
        toast.success(options.successMessage);
      }
      options.onSuccess?.(accepted);
    } catch (error) {
      const message = friendlyErrorMessage(error, options.errorMessage);
      if (!options.onError?.(message)) {
        toast.error(message);
      }
    } finally {
      setIsLoading(false);
      setBusyKey(null);
    }
  }

  return { isLoading, busyKey, run };
}
