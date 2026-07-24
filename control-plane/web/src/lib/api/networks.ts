// Network API endpoints

import { api } from "./client";
import type {
  Network,
  CreateNetworkRequest,
  UpdateNetworkRequest,
  Page,
} from "@/types/api";
import { LIST_PAGE_LIMIT } from "@/types/api";

export const networksApi = {
  list(projectId?: string): Promise<Network[]> {
    return api
      .get<Page<Network>>("/api/networks", {
        limit: LIST_PAGE_LIMIT,
        ...(projectId ? { project_id: projectId } : {}),
      })
      .then((page) => page.items);
  },

  get(id: string): Promise<Network> {
    return api.get<Network>(`/api/networks/${id}`);
  },

  create(data: CreateNetworkRequest): Promise<Network> {
    return api.post<Network>("/api/networks", data);
  },

  update(id: string, data: UpdateNetworkRequest): Promise<Network> {
    return api.put<Network>(`/api/networks/${id}`, data);
  },

  delete(id: string): Promise<void> {
    return api.delete(`/api/networks/${id}`);
  },
};
