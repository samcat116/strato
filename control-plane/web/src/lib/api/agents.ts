// Agent API endpoints

import { api } from "./client";
import type {
  Agent,
  AgentRegistrationToken,
  CreateAgentRegistrationTokenRequest,
} from "@/types/api";

export const agentsApi = {
  list(): Promise<Agent[]> {
    return api.get<Agent[]>("/api/agents");
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

  // Registration tokens
  listTokens(): Promise<AgentRegistrationToken[]> {
    return api.get<AgentRegistrationToken[]>("/api/agents/registration-tokens");
  },

  createToken(data: CreateAgentRegistrationTokenRequest): Promise<AgentRegistrationToken> {
    return api.post<AgentRegistrationToken>("/api/agents/registration-tokens", data);
  },

  revokeToken(tokenId: string): Promise<void> {
    return api.delete(`/api/agents/registration-tokens/${tokenId}`);
  },
};
