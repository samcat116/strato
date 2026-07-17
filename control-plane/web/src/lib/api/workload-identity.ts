// Workload Identity (SPIFFE / SPIRE) API endpoints

import { api } from "./client";
import type { WorkloadIdentityOverview } from "@/types/api";

export const workloadIdentityApi = {
  /** The trust domain's registration entries, node attestation, and trust bundle. */
  overview(): Promise<WorkloadIdentityOverview> {
    return api.get<WorkloadIdentityOverview>("/api/workload-identity");
  },
};
