// Resource Quota API endpoints

import { api } from "./client";
import type {
  ResourceQuota,
  CreateQuotaRequest,
  UpdateQuotaRequest,
} from "@/types/api";

export const quotasApi = {
  // List all quotas the user can access, optionally filtered by level
  list(level?: "organization" | "organizational_unit" | "project"): Promise<
    ResourceQuota[]
  > {
    return api.get<ResourceQuota[]>(
      "/api/quotas",
      level ? { level } : undefined
    );
  },

  get(quotaId: string): Promise<ResourceQuota> {
    return api.get<ResourceQuota>(`/api/quotas/${quotaId}`);
  },

  update(quotaId: string, data: UpdateQuotaRequest): Promise<ResourceQuota> {
    return api.put<ResourceQuota>(`/api/quotas/${quotaId}`, data);
  },

  delete(quotaId: string): Promise<void> {
    return api.delete(`/api/quotas/${quotaId}`);
  },

  // Scoped listing
  listForOrganization(organizationId: string): Promise<ResourceQuota[]> {
    return api.get<ResourceQuota[]>(
      `/api/organizations/${organizationId}/quotas`
    );
  },

  listForFolder(organizationId: string, ouId: string): Promise<ResourceQuota[]> {
    return api.get<ResourceQuota[]>(
      `/api/organizations/${organizationId}/ous/${ouId}/quotas`
    );
  },

  listForProject(projectId: string): Promise<ResourceQuota[]> {
    return api.get<ResourceQuota[]>(`/api/projects/${projectId}/quotas`);
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
