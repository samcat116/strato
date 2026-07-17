// Site (availability zone) API endpoints

import { api } from "./client";
import type { Site, CreateSiteRequest } from "@/types/api";

export const sitesApi = {
  list(organizationId?: string): Promise<Site[]> {
    return api.get<Site[]>(
      "/api/sites",
      organizationId ? { organization_id: organizationId } : undefined
    );
  },

  get(id: string): Promise<Site> {
    return api.get<Site>(`/api/sites/${id}`);
  },

  create(data: CreateSiteRequest): Promise<Site> {
    return api.post<Site>("/api/sites", data);
  },

  delete(id: string): Promise<void> {
    return api.delete(`/api/sites/${id}`);
  },

  assignAgent(siteId: string, agentId: string): Promise<void> {
    return api.post(`/api/sites/${siteId}/agents/${agentId}`);
  },

  removeAgent(siteId: string, agentId: string): Promise<void> {
    return api.delete(`/api/sites/${siteId}/agents/${agentId}`);
  },
};
