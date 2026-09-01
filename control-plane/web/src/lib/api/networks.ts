// Network API endpoints

import { api, ApiError } from "./client";
import { listAllPages } from "./pagination";
import type {
  Network,
  NetworkACL,
  NetworkACLRule,
  CreateNetworkRequest,
  CreateNetworkACLRuleRequest,
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

  async getACL(
    networkId: string,
    signal?: AbortSignal
  ): Promise<NetworkACL | null> {
    try {
      return await api.get<NetworkACL>(
        `/api/networks/${networkId}/acl`,
        undefined,
        signal
      );
    } catch (error) {
      // An ACL is optional. The backend represents absence as 404 because
      // there is no subresource to return, not as a failed network lookup.
      if (
        error instanceof ApiError &&
        error.status === 404 &&
        error.message === "Network ACL not found"
      ) {
        return null;
      }
      throw error;
    }
  },

  createACL(networkId: string): Promise<NetworkACL> {
    return api.post<NetworkACL>(`/api/networks/${networkId}/acl`);
  },

  deleteACL(networkId: string): Promise<void> {
    return api.delete(`/api/networks/${networkId}/acl`);
  },

  createACLRule(
    networkId: string,
    data: CreateNetworkACLRuleRequest
  ): Promise<NetworkACLRule> {
    return api.post<NetworkACLRule>(
      `/api/networks/${networkId}/acl/rules`,
      data
    );
  },

  deleteACLRule(networkId: string, ruleId: string): Promise<void> {
    return api.delete(`/api/networks/${networkId}/acl/rules/${ruleId}`);
  },
};
