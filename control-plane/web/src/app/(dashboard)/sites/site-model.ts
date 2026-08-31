import { reservedPercent } from "@/components/overview";
import type { Agent, Site, SiteStatus, VM } from "@/types/api";

export const SITE_STATUSES: SiteStatus[] = [
  "active",
  "draining",
  "maintenance",
  "decommissioned",
];

export type DisplayStatus = "healthy" | "degraded" | "provisioning";
export type StatusFilter = "all" | DisplayStatus;

export const STATUS_STYLES: Record<DisplayStatus, { label: string; dot: string }> = {
  healthy: { label: "Healthy", dot: "#16a34a" },
  degraded: { label: "Degraded", dot: "#d97706" },
  provisioning: { label: "Provisioning", dot: "#94a3b8" },
};

export interface SiteFormState {
  name: string;
  description: string;
  status: SiteStatus;
  regionCode: string;
  locationLabel: string;
  latitude: string;
  longitude: string;
  labels: Array<{ key: string; value: string }>;
  networkControllerAgentId: string;
}

export const EMPTY_FORM: SiteFormState = {
  name: "",
  description: "",
  status: "active",
  regionCode: "",
  locationLabel: "",
  latitude: "",
  longitude: "",
  labels: [],
  networkControllerAgentId: "",
};

export function displayStatus(
  site: Site,
  members: Agent[],
  agentsKnown: boolean
): DisplayStatus {
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

export function siteMembers(siteId: string, agents: Agent[]): Agent[] {
  return agents.filter((agent) => agent.siteId === siteId);
}

export function siteInstances(siteId: string, agents: Agent[], vms: VM[]): VM[] {
  const agentIds = new Set(
    agents
      .filter((agent) => agent.siteId === siteId)
      .map((agent) => agent.id.toLowerCase())
  );
  return vms.filter(
    (vm) => vm.hypervisorId && agentIds.has(vm.hypervisorId.toLowerCase())
  );
}

export function siteCapacity(members: Agent[]): number {
  const online = members.filter((agent) => agent.isOnline);
  const total = online.reduce((sum, agent) => sum + agent.resources.totalCPU, 0);
  const available = online.reduce(
    (sum, agent) => sum + agent.resources.availableCPU,
    0
  );
  return reservedPercent(total, available);
}
