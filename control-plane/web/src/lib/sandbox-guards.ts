import type { Sandbox } from "@/types/api";

type SnapshotAdmissionSandbox = Pick<
  Sandbox,
  "status" | "hypervisorId" | "conditions"
>;

/**
 * Client-side mirror of the placement and lifecycle checks at the start of
 * `SandboxSnapshotController.createSnapshot`.
 *
 * A newly inserted sandbox reports `Stopped`, but it is not capturable until
 * an agent owns it and has confirmed at least one generation. Keep those
 * requirements explicit instead of treating every stable-looking status as a
 * materialized microVM.
 */
export function sandboxCanBeSnapshotted(
  sandbox: SnapshotAdmissionSandbox
): boolean {
  const stableState =
    sandbox.status === "Running" ||
    sandbox.status === "Stopped" ||
    sandbox.status === "Exited";

  return (
    stableState &&
    !!sandbox.hypervisorId &&
    sandbox.conditions.observedGeneration > 0
  );
}
