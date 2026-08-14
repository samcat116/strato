// Site (availability zone) API endpoints

import { api } from "./client";
import { listAllPages } from "./pagination";
import type {
  Site,
  CreateSiteRequest,
  UpdateSiteRequest,
} from "@/types/api";

export const sitesApi = {
  list(organizationId?: string, signal?: AbortSignal): Promise<Site[]> {
    return listAllPages<Site>(
      "/api/sites",
      organizationId ? { organization_id: organizationId } : {}, signal
    );
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
};
