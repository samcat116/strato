// Agent API endpoints

import { api } from "./client";
import { listAllPages } from "./pagination";
import type {
  AdoptWorkloadsResult,
  Agent,
  AgentEnrollment,
  AgentUpdateResult,
  CreateAgentEnrollmentRequest,
} from "@/types/api";

export const agentsApi = {
  list(organizationId?: string, signal?: AbortSignal): Promise<Agent[]> {
    return listAllPages<Agent>(
      "/api/agents",
      organizationId ? { organization_id: organizationId } : {}, signal
    );
  },

  get(id: string, signal?: AbortSignal): Promise<Agent> {
    return api.get<Agent>(`/api/agents/${id}`, undefined, signal);
  },

  // Assigns the target version as desired state and returns 202 immediately
  // (STR-145). The agent converges on its next sync; watch
  // `updateDesiredVersion` / `updateBlockedReason` / `updateFailureReason` on
  // the agent for progress.
  update(id: string, options?: { force?: boolean }): Promise<AgentUpdateResult> {
    return api.post<AgentUpdateResult>(`/api/agents/${id}/actions/update`, options ?? {});
  },

  // Withdraws an update assignment (rollout's or an operator's). Works while
  // the agent is offline, which is when a stuck update usually needs clearing.
  cancelUpdate(id: string): Promise<Agent> {
    return api.delete<Agent>(`/api/agents/${id}/actions/update`);
  },

  patch(id: string, data: { autoUpdate?: boolean }): Promise<Agent> {
    return api.patch<Agent>(`/api/agents/${id}`, data);
  },

  forceOffline(id: string): Promise<Agent> {
    return api.post<Agent>(`/api/agents/${id}/actions/force-offline`);
  },

  // Moves the workloads this agent is demonstrably running off the agent
  // record they are still placed on (STR-98).
  adoptWorkloads(id: string, fromAgentId: string): Promise<AdoptWorkloadsResult> {
    return api.post<AdoptWorkloadsResult>(`/api/agents/${id}/actions/adopt-workloads`, {
      fromAgentId,
    });
  },

  // SPIFFE/SPIRE enrollments — the only agent enrollment path.
  createEnrollment(data: CreateAgentEnrollmentRequest): Promise<AgentEnrollment> {
    return api.post<AgentEnrollment>("/api/agent-enrollments", data);
  },
};
