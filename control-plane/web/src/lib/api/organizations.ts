// Organization API endpoints

import { api } from "./client";
import type {
  Organization,
  OrganizationMember,
  CreateOrganizationRequest,
  UpdateOrganizationRequest,
} from "@/types/api";

export const organizationsApi = {
  list(): Promise<Organization[]> {
    return api.get<Organization[]>("/organizations");
  },

  get(id: string): Promise<Organization> {
    return api.get<Organization>(`/organizations/${id}`);
  },

  create(data: CreateOrganizationRequest): Promise<Organization> {
    return api.post<Organization>("/organizations", data);
  },

  update(id: string, data: UpdateOrganizationRequest): Promise<Organization> {
    return api.put<Organization>(`/organizations/${id}`, data);
  },

  delete(id: string): Promise<void> {
    return api.delete(`/organizations/${id}`);
  },

  switch(id: string): Promise<void> {
    return api.post(`/organizations/${id}/switch`);
  },

  // Members
  listMembers(orgId: string): Promise<OrganizationMember[]> {
    return api.get<OrganizationMember[]>(`/organizations/${orgId}/members`);
  },

  addMember(orgId: string, userId: string, role: string): Promise<void> {
    return api.post(`/organizations/${orgId}/members`, { userId, role });
  },

  removeMember(orgId: string, userId: string): Promise<void> {
    return api.delete(`/organizations/${orgId}/members/${userId}`);
  },

  updateMemberRole(orgId: string, userId: string, role: string): Promise<void> {
    return api.patch(`/organizations/${orgId}/members/${userId}`, { role });
  },
};
