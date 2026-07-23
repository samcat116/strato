/**
 * Catalog of subscribable webhook event types. Mirrors the backend's event
 * vocabulary; an empty `eventTypes` array on a subscription means all of them.
 */
export interface WebhookEventTypeInfo {
  type: string;
  label: string;
  description: string;
}

export const WEBHOOK_EVENT_TYPES: WebhookEventTypeInfo[] = [
  {
    type: "operation.completed",
    label: "Operation completed",
    description: "An async VM or sandbox operation succeeded.",
  },
  {
    type: "operation.failed",
    label: "Operation failed",
    description: "An async VM or sandbox operation failed.",
  },
  {
    type: "vm.state_changed",
    label: "VM state changed",
    description: "A VM's observed status transitioned.",
  },
  {
    type: "agent.connected",
    label: "Agent connected",
    description: "A hypervisor agent connected to the control plane.",
  },
  {
    type: "agent.disconnected",
    label: "Agent disconnected",
    description: "A hypervisor agent disconnected from the control plane.",
  },
  {
    type: "quota.threshold_exceeded",
    label: "Quota threshold exceeded",
    description: "A quota pool crossed 80% or 100% of its limit.",
  },
];

export function webhookEventLabel(type: string): string {
  return WEBHOOK_EVENT_TYPES.find((e) => e.type === type)?.label ?? type;
}
