import type { WorkloadRegistration } from "@/lib/api/platform-services";

export function workloadRegistrationDeletionMessage(
  registration: WorkloadRegistration
): string {
  if (registration.vmId) {
    const vmName = registration.displayName ?? "Unnamed VM";
    return `Delete workload identity ${registration.spiffeId} for VM "${vmName}" (${registration.vmId})? This permanently revokes the VM's identity and access. It will not be recreated, and this action cannot be undone.`;
  }

  const workloadName =
    registration.displayName ?? registration.agentName ?? registration.kind;
  return `Delete workload identity ${registration.spiffeId} for ${workloadName}? This action cannot be undone.`;
}
