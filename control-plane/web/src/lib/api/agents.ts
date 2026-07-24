// Agent API endpoints

import { api } from "./client";
import type {
  Agent,
  AgentEnrollment,
  AgentEnrollmentListItem,
  AgentUpdateResult,
  CreateAgentEnrollmentRequest,
  Page,
} from "@/types/api";
import { LIST_PAGE_LIMIT } from "@/types/api";

export const agentsApi = {
  list(organizationId?: string): Promise<Agent[]> {
    return api
      .get<Page<Agent>>("/api/agents", {
        limit: LIST_PAGE_LIMIT,
        ...(organizationId ? { organization_id: organizationId } : {}),
      })
      .then((page) => page.items);
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
    return api
      .get<Page<AgentEnrollmentListItem>>("/api/agent-enrollments", {
        limit: LIST_PAGE_LIMIT,
        ...(organizationId ? { organization_id: organizationId } : {}),
      })
      .then((page) => page.items);
  },

  createEnrollment(data: CreateAgentEnrollmentRequest): Promise<AgentEnrollment> {
    return api.post<AgentEnrollment>("/api/agent-enrollments", data);
  },

  revokeEnrollment(enrollmentId: string): Promise<void> {
    return api.delete(`/api/agent-enrollments/${enrollmentId}`);
  },
};
