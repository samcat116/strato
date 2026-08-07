import type { OperationKind } from "@/types/api";

// Labels for the states that only exist as an in-flight mutation (the server
// keeps the resource's resting status until the agent confirms). Shared by the
// VM, sandbox and volume status badges: no resource carries every kind — VMs
// never snapshot-export, sandboxes never pause/resume, volumes never boot — but
// the map stays total over OperationKind so a new variant is a compile error
// rather than a blank badge.
const pendingMutationLabels: Record<OperationKind, string> = {
  create: "Creating",
  boot: "Starting",
  shutdown: "Stopping",
  reboot: "Restarting",
  pause: "Pausing",
  resume: "Resuming",
  delete: "Deleting",
  resize: "Resizing",
  snapshot: "Snapshotting",
  snapshot_delete: "Deleting snapshot",
  restore: "Restoring",
  snapshot_export: "Exporting snapshot",
  attach: "Attaching",
  detach: "Detaching",
};

/**
 * What to show on a status badge while `kind` is in flight.
 *
 * The map is total over the union, but a control plane running ahead of the
 * frontend can send a kind this build doesn't declare — the lookup is a miss at
 * runtime even though the types say otherwise. A generic label beats the blank
 * badge that `undefined` would render.
 */
export function pendingMutationLabel(kind: OperationKind): string {
  return pendingMutationLabels[kind] ?? "Working";
}
