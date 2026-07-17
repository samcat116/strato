// Agent API endpoints

import { api } from "./client";
import type {
  Agent,
  AgentRegistrationToken,
  AgentRegistrationTokenListItem,
  AgentUpdateResult,
  CreateAgentRegistrationTokenRequest,
} from "@/types/api";

export const agentsApi = {
  list(organizationId?: string): Promise<Agent[]> {
    return api.get<Agent[]>(
      "/api/agents",
      organizationId ? { organization_id: organizationId } : undefined
    );
  },

  get(id: string): Promise<Agent> {
    return api.get<Agent>(`/api/agents/${id}`);
  },

  deregister(id: string): Promise<void> {
    return api.delete(`/api/agents/${id}`);
  },

  forceOffline(id: string): Promise<void> {
    return api.post(`/api/agents/${id}/actions/force-offline`);
  },

  // Synchronous long poll: the control plane replies only after the agent has
  // downloaded, verified, and installed the new binary (or refused).
  update(id: string, options?: { force?: boolean }): Promise<AgentUpdateResult> {
    return api.post<AgentUpdateResult>(`/api/agents/${id}/actions/update`, options ?? {});
  },

  patch(id: string, data: { autoUpdate?: boolean }): Promise<Agent> {
    return api.patch<Agent>(`/api/agents/${id}`, data);
  },

  // Registration tokens
  listTokens(organizationId?: string): Promise<AgentRegistrationTokenListItem[]> {
    return api.get<AgentRegistrationTokenListItem[]>(
      "/api/agents/registration-tokens",
      organizationId ? { organization_id: organizationId } : undefined
    );
  },

  createToken(data: CreateAgentRegistrationTokenRequest): Promise<AgentRegistrationToken> {
    return api.post<AgentRegistrationToken>("/api/agents/registration-tokens", data);
  },

  revokeToken(tokenId: string): Promise<void> {
    return api.delete(`/api/agents/registration-tokens/${tokenId}`);
  },
};
