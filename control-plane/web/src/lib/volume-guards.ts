import type { Volume } from "@/types/api";

/**
 * Whether a volume's bytes are settled enough to be copied — the client-side
 * mirror of the backend's `Volume.bytesAtRest`.
 *
 * Deliberately *not* `conditions.converged` (backend STR-191). Convergence now
 * also excludes a failure recorded at the current generation, and for a volume
 * nothing clears one: the failure resolution bumps the generation only for a
 * failed attach, so a resize that failed would grey out Snapshot and Clone
 * permanently, with no explanation and no action the user could take. It is
 * also the wrong question. A failed *change* does not tear the bytes — the
 * backend derives `creating`/`error` for a volume whose bytes are absent, so a
 * half-written one can never reach a resting status — and a copy of the
 * pre-resize volume is a perfectly good point-in-time copy.
 */
export function volumeBytesAtRest(volume: Volume): boolean {
  return (
    volume.conditions.observedGeneration >= volume.conditions.targetGeneration &&
    (volume.status === "available" || volume.status === "attached")
  );
}
