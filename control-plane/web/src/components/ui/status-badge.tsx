"use client";

import { Badge } from "@/components/ui/badge";
import { pendingMutationLabel } from "@/lib/operation-labels";
import { usePendingMutation } from "@/lib/stores/mutations-store";

export interface StatusBadgeConfig {
  label: string;
  className: string;
}

// A control plane running ahead of this build can report a status the config
// map doesn't declare; the lookup misses at runtime even though the types say
// otherwise, and a generic badge beats a blank one.
const unknownConfig: StatusBadgeConfig = {
  label: "Unknown",
  className: "bg-gray-500/20 text-muted-foreground border-gray-500/30",
};

/**
 * Status badge shared by VMs, sandboxes, volumes and snapshots: a per-kind
 * config map picks the label and colors, and — when a `resourceId` is given —
 * an in-flight mutation on that resource overrides the status with the
 * mutation's verb, pulsing until the watcher sees a terminal state.
 */
export function StatusBadge<Status extends string>({
  status,
  config,
  resourceId,
  pendingClassName = "bg-blue-500/20 text-blue-600 border-blue-500/30 animate-pulse",
}: {
  status: Status;
  config: Record<Status, StatusBadgeConfig>;
  /** When provided, an in-flight mutation on this resource overrides the status label. */
  resourceId?: string;
  /** Badge classes while a pending mutation overrides the label. */
  pendingClassName?: string;
}) {
  const pendingMutation = usePendingMutation(resourceId);

  if (pendingMutation) {
    return (
      <Badge variant="outline" className={pendingClassName}>
        {pendingMutationLabel(pendingMutation.kind)}
      </Badge>
    );
  }

  const entry = config[status] || unknownConfig;

  return (
    <Badge variant="outline" className={entry.className}>
      {entry.label}
    </Badge>
  );
}
