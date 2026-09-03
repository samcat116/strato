// Hierarchy (org -> folder -> project -> resources) API endpoints

import { api } from "./client";
import type {
  OrganizationHierarchy,
  HierarchySearchResponse,
} from "@/types/api";

export const hierarchyApi = {
  // Full hierarchy tree for an organization
  get(organizationId: string, signal?: AbortSignal): Promise<OrganizationHierarchy> {
    return api.get<OrganizationHierarchy>(
      `/api/organizations/${organizationId}/hierarchy`, undefined, signal
    );
  },

  // Search within a single organization
  search(
    organizationId: string,
    query: string,
    type?: string,
    signal?: AbortSignal
  ): Promise<HierarchySearchResponse> {
    const params: Record<string, string> = { q: query };
    if (type) params.type = type;
    return api.get<HierarchySearchResponse>(
      `/api/organizations/${organizationId}/search`,
      params,
      signal
    );
  },
};
