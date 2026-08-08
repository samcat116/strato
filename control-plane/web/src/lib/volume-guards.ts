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
 *
 * Two of the backend's three clauses, not all three: it also requires
 * `desiredStatus == .present`, and `Volume` does not carry desired status. No
 * reachable case is known — a delete bumps the generation, and the agent
 * advances its applied generation only once the delete work item succeeds, at
 * which point the volume is omitted from its report rather than reported
 * present — so `observedGeneration >= targetGeneration` on a terminating volume
 * that still reads `available` is not a state the loop produces. It is called
 * out because the guard this replaced (`conditions.converged`) would have
 * inherited the clause for free. Closing it properly means putting
 * `canSnapshot`/`canClone` on `VolumeResponse` and deleting this mirror
 * entirely, which is the better fix and a separate change.
 */
export function volumeBytesAtRest(volume: Volume): boolean {
  return (
    volume.conditions.observedGeneration >= volume.conditions.targetGeneration &&
    (volume.status === "available" || volume.status === "attached")
  );
}
