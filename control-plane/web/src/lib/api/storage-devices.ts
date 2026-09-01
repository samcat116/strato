import { api } from "./client";
import { listAllPages } from "./pagination";
import type { StorageDevice, UpdateStorageDeviceRequest } from "@/types/api-contracts";

export interface StorageDeviceFilters {
  organizationId?: string;
  siteId?: string;
  agentId?: string;
}

export const storageDevicesApi = {
  list(filters: StorageDeviceFilters, signal?: AbortSignal): Promise<StorageDevice[]> {
    const params: Record<string, string> = {};
    if (filters.organizationId) params.organization_id = filters.organizationId;
    if (filters.siteId) params.site_id = filters.siteId;
    if (filters.agentId) params.agent_id = filters.agentId;
    return listAllPages<StorageDevice>("/api/storage-devices", params, signal);
  },

  setOsdEligibility(deviceId: string, osdEligible: boolean): Promise<StorageDevice> {
    const request: UpdateStorageDeviceRequest = { osdEligible };
    return api.patch<StorageDevice>(`/api/storage-devices/${deviceId}`, request);
  },
};
