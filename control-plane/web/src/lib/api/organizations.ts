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
    return api.get<Organization[]>("/api/organizations");
  },

  get(id: string): Promise<Organization> {
    return api.get<Organization>(`/api/organizations/${id}`);
  },

  create(data: CreateOrganizationRequest): Promise<Organization> {
    return api.post<Organization>("/api/organizations", data);
  },

  update(id: string, data: UpdateOrganizationRequest): Promise<Organization> {
    return api.put<Organization>(`/api/organizations/${id}`, data);
  },

  delete(id: string): Promise<void> {
    return api.delete(`/api/organizations/${id}`);
  },

  switch(id: string): Promise<void> {
    return api.post(`/api/organizations/${id}/switch`);
  },

  // Members
  listMembers(orgId: string): Promise<OrganizationMember[]> {
    return api.get<OrganizationMember[]>(`/api/organizations/${orgId}/members`);
  },

  addMember(orgId: string, userId: string, role: string): Promise<void> {
    return api.post(`/api/organizations/${orgId}/members`, { userId, role });
  },

  removeMember(orgId: string, userId: string): Promise<void> {
    return api.delete(`/api/organizations/${orgId}/members/${userId}`);
  },

  updateMemberRole(orgId: string, userId: string, role: string): Promise<void> {
    return api.patch(`/api/organizations/${orgId}/members/${userId}`, { role });
  },
};
