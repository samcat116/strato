// Network API endpoints

import { api } from "./client";
import { listAllPages } from "./pagination";
import type {
  Network,
  CreateNetworkRequest,
  UpdateNetworkRequest,
} from "@/types/api-contracts";

export const networksApi = {
  list(projectId?: string, signal?: AbortSignal): Promise<Network[]> {
    return listAllPages<Network>(
      "/api/networks",
      projectId ? { project_id: projectId } : {}, signal
    );
  },

  get(id: string, signal?: AbortSignal): Promise<Network> {
    return api.get<Network>(`/api/networks/${id}`, undefined, signal);
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
