// Workload Identity (SPIFFE / SPIRE) API endpoints

import { api } from "./client";
import type { WorkloadIdentityOverview } from "@/types/api-contracts";

export const workloadIdentityApi = {
  /** The trust domain's registration entries, node attestation, and trust bundle. */
  overview(signal?: AbortSignal): Promise<WorkloadIdentityOverview> {
    return api.get<WorkloadIdentityOverview>("/api/workload-identity", undefined, signal);
  },
};
