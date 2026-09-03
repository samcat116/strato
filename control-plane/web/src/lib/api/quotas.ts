// Resource Quota API endpoints

import { api } from "./client";
import type {
  ResourceQuota,
  CreateQuotaRequest,
  UpdateQuotaRequest,
} from "@/types/api";

export const quotasApi = {
  update(quotaId: string, data: UpdateQuotaRequest): Promise<ResourceQuota> {
    return api.put<ResourceQuota>(`/api/quotas/${quotaId}`, data);
  },

  delete(quotaId: string): Promise<void> {
    return api.delete(`/api/quotas/${quotaId}`);
  },

  // Scoped creation
  createForOrganization(
    organizationId: string,
    data: CreateQuotaRequest
  ): Promise<ResourceQuota> {
    return api.post<ResourceQuota>(
      `/api/organizations/${organizationId}/quotas`,
      data
    );
  },

  createForOU(
    organizationId: string,
    ouId: string,
    data: CreateQuotaRequest
  ): Promise<ResourceQuota> {
    return api.post<ResourceQuota>(
      `/api/organizations/${organizationId}/ous/${ouId}/quotas`,
      data
    );
  },

  createForProject(
    projectId: string,
    data: CreateQuotaRequest
  ): Promise<ResourceQuota> {
    return api.post<ResourceQuota>(`/api/projects/${projectId}/quotas`, data);
  },
};
