// Group API endpoints (scoped to an organization)

import { api } from "./client";
import type {
  Group,
  GroupMember,
  CreateGroupRequest,
  UpdateGroupRequest,
} from "@/types/api";

export const groupsApi = {
  list(orgId: string): Promise<Group[]> {
    return api.get<Group[]>(`/api/organizations/${orgId}/groups`);
  },

  get(orgId: string, groupId: string): Promise<Group> {
    return api.get<Group>(`/api/organizations/${orgId}/groups/${groupId}`);
  },

  create(orgId: string, data: CreateGroupRequest): Promise<Group> {
    return api.post<Group>(`/api/organizations/${orgId}/groups`, data);
  },

  update(
    orgId: string,
    groupId: string,
    data: UpdateGroupRequest
  ): Promise<Group> {
    return api.put<Group>(
      `/api/organizations/${orgId}/groups/${groupId}`,
      data
    );
  },

  delete(orgId: string, groupId: string): Promise<void> {
    return api.delete(`/api/organizations/${orgId}/groups/${groupId}`);
  },

  // Members
  listMembers(orgId: string, groupId: string): Promise<GroupMember[]> {
    return api.get<GroupMember[]>(
      `/api/organizations/${orgId}/groups/${groupId}/members`
    );
  },

  addMembers(orgId: string, groupId: string, userIds: string[]): Promise<void> {
    return api.post(`/api/organizations/${orgId}/groups/${groupId}/members`, {
      userIds,
    });
  },

  removeMember(orgId: string, groupId: string, userId: string): Promise<void> {
    return api.delete(
      `/api/organizations/${orgId}/groups/${groupId}/members/${userId}`
    );
  },
};
