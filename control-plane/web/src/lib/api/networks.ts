// Network API endpoints

import { api } from "./client";
import type {
  Network,
  CreateNetworkRequest,
  UpdateNetworkRequest,
} from "@/types/api";

export const networksApi = {
  list(projectId?: string): Promise<Network[]> {
    return api.get<Network[]>(
      "/api/networks",
      projectId ? { project_id: projectId } : undefined
    );
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
