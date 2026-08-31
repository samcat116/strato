import { reservedPercent } from "@/components/overview";
import type { Agent, Site, VM } from "@/types/api";

export type SiteDisplayStatus = "healthy" | "degraded" | "provisioning";
export type SiteStatusFilter = "all" | SiteDisplayStatus;

export const SITE_STATUS_STYLES: Record<
  SiteDisplayStatus,
  { label: string; dot: string }
> = {
  healthy: { label: "Healthy", dot: "#16a34a" },
  degraded: { label: "Degraded", dot: "#d97706" },
  provisioning: { label: "Provisioning", dot: "#94a3b8" },
};

export function siteDisplayStatus(
  site: Site,
  members: Agent[],
  agentsKnown: boolean
): SiteDisplayStatus {
  if (agentsKnown && members.length === 0 && site.status === "active") {
    return "provisioning";
  }
  if (
    site.status === "active" &&
    site.networkControllerAgentId &&
    !site.networkControllerIssue &&
    (!site.networkControllerStatus || site.networkControllerStatus === "online")
  ) {
    return "healthy";
  }
  return "degraded";
}

export function agentsAtSite(siteId: string, agents: Agent[]): Agent[] {
  return agents.filter((agent) => agent.siteId === siteId);
}

export function instancesAtSite(siteId: string, agents: Agent[], vms: VM[]): VM[] {
  const agentIds = new Set(
    agents
      .filter((agent) => agent.siteId === siteId)
      .map((agent) => agent.id.toLowerCase())
  );
  return vms.filter(
    (vm) => vm.hypervisorId && agentIds.has(vm.hypervisorId.toLowerCase())
  );
}

export function siteReservedCapacity(members: Agent[]): number {
  const online = members.filter((agent) => agent.isOnline);
  const total = online.reduce((sum, agent) => sum + agent.resources.totalCPU, 0);
  const available = online.reduce(
    (sum, agent) => sum + agent.resources.availableCPU,
    0
  );
  return reservedPercent(total, available);
}
