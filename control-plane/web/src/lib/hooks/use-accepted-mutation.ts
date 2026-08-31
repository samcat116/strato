import { useRef, useState } from "react";
import { toast } from "sonner";
import { ApiError } from "@/lib/api/client";
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
  /** Stable fingerprint of the HTTP method, target, and request body. */
  intentKey: string;
  /** The 202-returning API call. */
  request: (idempotencyKey: string) => Promise<AcceptedMutation<Resource>>;
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

function newIdempotencyKey(): string {
  if (typeof crypto.randomUUID === "function") {
    try {
      return crypto.randomUUID();
    } catch {
      // Some browsers expose the method on plaintext origins but reject the
      // call. Fall through to the Web Crypto primitive allowed there.
    }
  }

  // `randomUUID` is secure-context-only, but `getRandomValues` remains
  // available on Strato's supported plaintext HTTP deployments. Build an
  // RFC 4122 version-4 UUID from those random bytes there.
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0"));
  return [
    hex.slice(0, 4).join(""),
    hex.slice(4, 6).join(""),
    hex.slice(6, 8).join(""),
    hex.slice(8, 10).join(""),
    hex.slice(10).join(""),
  ].join("-");
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
  const inFlight = useRef<Promise<void> | null>(null);
  const ambiguousAttempt = useRef<{
    intentKey: string;
    idempotencyKey: string;
  } | null>(null);

  function run<Resource extends { id?: string }>(
    options: RunAcceptedMutationOptions<Resource>
  ): Promise<void> {
    // React state does not update soon enough to stop two submit events in the
    // same tick. Share the actual promise so a double click remains one form
    // submission and therefore one idempotency key.
    if (inFlight.current) return inFlight.current;

    const promise = (async () => {
      setIsLoading(true);
      setBusyKey(options.busyKey ?? null);
      const previous = ambiguousAttempt.current;
      const idempotencyKey =
        previous?.intentKey === options.intentKey
          ? previous.idempotencyKey
          : newIdempotencyKey();
      ambiguousAttempt.current = { intentKey: options.intentKey, idempotencyKey };
      try {
        const accepted = await options.request(idempotencyKey);
        // A decoded response is definitive. The next submission is a new
        // intent even if its fields happen to be identical.
        ambiguousAttempt.current = null;
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
        // A 4xx response definitively rejected this delivery, so another
        // submission is a new attempt. Transport failures and 5xx responses
        // are ambiguous: a gateway may have lost the upstream response, and
        // the control plane can fail while recording a committed response.
        if (error instanceof ApiError && error.status < 500) {
          ambiguousAttempt.current = null;
        }
        const message = friendlyErrorMessage(error, options.errorMessage);
        if (!options.onError?.(message)) {
          toast.error(message);
        }
      } finally {
        setIsLoading(false);
        setBusyKey(null);
        inFlight.current = null;
      }
    })();
    inFlight.current = promise;
    return promise;
  }

  return { isLoading, busyKey, run };
}
