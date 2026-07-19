// Agent API endpoints

import { api } from "./client";
import type {
  Agent,
  AgentEnrollment,
  AgentEnrollmentListItem,
  AgentUpdateResult,
  CreateAgentEnrollmentRequest,
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

  // SPIFFE/SPIRE enrollments — the only agent enrollment path.
  listEnrollments(organizationId?: string): Promise<AgentEnrollmentListItem[]> {
    return api.get<AgentEnrollmentListItem[]>(
      "/api/agents/enrollments",
      organizationId ? { organization_id: organizationId } : undefined
    );
  },

  createEnrollment(data: CreateAgentEnrollmentRequest): Promise<AgentEnrollment> {
    return api.post<AgentEnrollment>("/api/agents/enrollments", data);
  },

  revokeEnrollment(enrollmentId: string): Promise<void> {
    return api.delete(`/api/agents/enrollments/${enrollmentId}`);
  },
};
