import type { OperationKind } from "@/types/api";

// Labels for the states that only exist as an in-flight mutation (the server
// keeps the resource's resting status until the agent confirms). Shared by the
// VM and sandbox status badges: neither resource carries every kind — VMs never
// snapshot-export, sandboxes never pause/resume — but the map stays total over
// OperationKind so a new variant is a compile error rather than a blank badge.
export const pendingMutationLabels: Record<OperationKind, string> = {
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
};
