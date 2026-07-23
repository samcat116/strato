// Site (availability zone) API endpoints

import { api } from "./client";
import type { Site, CreateSiteRequest, UpdateSiteRequest } from "@/types/api";

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

  // PUT is full-replace for descriptive fields; an omitted `status` leaves the
  // current lifecycle unchanged. Callers building an update from an existing
  // Site should echo the fields they want to keep.
  update(id: string, data: UpdateSiteRequest): Promise<Site> {
    return api.put<Site>(`/api/sites/${id}`, data);
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
