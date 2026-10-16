import type { SiteStatus, WorkloadResourceClassPolicy } from "@/types/api";

export {
  agentsAtSite as siteMembers,
  instancesAtSite as siteInstances,
  siteDisplayStatus as displayStatus,
  siteReservedCapacity as siteCapacity,
  SITE_STATUS_STYLES as STATUS_STYLES,
} from "@/lib/site-presentation";
export type {
  SiteDisplayStatus as DisplayStatus,
  SiteStatusFilter as StatusFilter,
} from "@/lib/site-presentation";

export const SITE_STATUSES: SiteStatus[] = [
  "active",
  "draining",
  "maintenance",
  "decommissioned",
];

export interface SiteFormState {
  burstablePolicy: WorkloadResourceClassPolicy;
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
  burstablePolicy: { kind: "burstable", cpuAllocationRatio: 4, memoryAllocationRatio: 1, cpuWeight: 100,
    memoryHighPercent: 80, hardLimitPolicy: "guestAndBackend", maxCPUPressure10: 10, maxMemoryPressure10: 5, maxTelemetryAgeSeconds: 60 },
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
