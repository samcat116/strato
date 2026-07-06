// Project-level role grant endpoints (users and groups)

import { api } from "./client";
import type { ProjectMembers, ProjectRole } from "@/types/api";

export const projectMembersApi = {
  list(projectId: string): Promise<ProjectMembers> {
    return api.get<ProjectMembers>(`/api/projects/${projectId}/members`);
  },

  grant(
    projectId: string,
    userEmail: string,
    role: ProjectRole
  ): Promise<void> {
    return api.post(`/api/projects/${projectId}/members`, { userEmail, role });
  },

  updateRole(
    projectId: string,
    userId: string,
    role: ProjectRole
  ): Promise<void> {
    return api.patch(`/api/projects/${projectId}/members/${userId}`, { role });
  },

  revoke(projectId: string, userId: string): Promise<void> {
    return api.delete(`/api/projects/${projectId}/members/${userId}`);
  },

  grantGroup(
    projectId: string,
    groupID: string,
    role: ProjectRole
  ): Promise<void> {
    return api.post(`/api/projects/${projectId}/groups`, { groupID, role });
  },

  revokeGroup(projectId: string, groupId: string): Promise<void> {
    return api.delete(`/api/projects/${projectId}/groups/${groupId}`);
  },
};
