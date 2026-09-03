// Project-level role grant endpoints (users, groups, and workloads)

import { api } from "./client";
import type {
  GrantWriteResponse,
  ProjectMembers,
  ProjectRole,
  ProjectVMPrincipal,
  VMProjectGrantResponse,
} from "@/types/api";

export const projectMembersApi = {
  list(projectId: string, signal?: AbortSignal): Promise<ProjectMembers> {
    return api.get<ProjectMembers>(`/api/projects/${projectId}/members`, undefined, signal);
  },

  listVMPrincipals(projectId: string, signal?: AbortSignal): Promise<ProjectVMPrincipal[]> {
    return api.get<ProjectVMPrincipal[]>(
      `/api/projects/${projectId}/vm-principals`, undefined, signal
    );
  },

  getVMProjectGrant(vmId: string, signal?: AbortSignal): Promise<VMProjectGrantResponse> {
    return api.get<VMProjectGrantResponse>(`/api/vms/${vmId}/project-grant`, undefined, signal);
  },

  grant(
    projectId: string,
    userEmail: string,
    role: ProjectRole
  ): Promise<GrantWriteResponse> {
    return api.post(`/api/projects/${projectId}/members`, { userEmail, role });
  },

  updateRole(
    projectId: string,
    userId: string,
    role: ProjectRole
  ): Promise<GrantWriteResponse> {
    return api.patch(`/api/projects/${projectId}/members/${userId}`, { role });
  },

  revoke(projectId: string, userId: string): Promise<void> {
    return api.delete(`/api/projects/${projectId}/members/${userId}`);
  },

  grantGroup(
    projectId: string,
    groupID: string,
    role: ProjectRole
  ): Promise<GrantWriteResponse> {
    return api.post(`/api/projects/${projectId}/groups`, { groupID, role });
  },

  revokeGroup(projectId: string, groupId: string): Promise<void> {
    return api.delete(`/api/projects/${projectId}/groups/${groupId}`);
  },

  grantWorkload(
    projectId: string,
    registrationId: string,
    role: ProjectRole
  ): Promise<GrantWriteResponse> {
    return api.put(
      `/api/projects/${projectId}/workload-grants/${registrationId}`,
      { role }
    );
  },

  revokeWorkload(projectId: string, registrationId: string): Promise<void> {
    return api.delete(
      `/api/projects/${projectId}/workload-grants/${registrationId}`
    );
  },
};
