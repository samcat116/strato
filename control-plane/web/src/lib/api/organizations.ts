// Organization API endpoints

import { api } from "./client";
import type {
  Organization,
  OrganizationMember,
  CreateOrganizationRequest,
  UpdateOrganizationRequest,
} from "@/types/api";

export const organizationsApi = {
  list(signal?: AbortSignal): Promise<Organization[]> {
    return api.get<Organization[]>("/api/organizations", undefined, signal);
  },

  // System-admin only: every organization, regardless of membership.
  listAll(signal?: AbortSignal): Promise<Organization[]> {
    return api.get<Organization[]>("/api/organizations/all", undefined, signal);
  },

  get(id: string, signal?: AbortSignal): Promise<Organization> {
    return api.get<Organization>(`/api/organizations/${id}`, undefined, signal);
  },

  create(data: CreateOrganizationRequest): Promise<Organization> {
    return api.post<Organization>("/api/organizations", data);
  },

  update(id: string, data: UpdateOrganizationRequest): Promise<Organization> {
    return api.put<Organization>(`/api/organizations/${id}`, data);
  },

  switch(id: string): Promise<void> {
    return api.post(`/api/organizations/${id}/switch`);
  },

  // Members
  listMembers(orgId: string, signal?: AbortSignal): Promise<OrganizationMember[]> {
    return api.get<OrganizationMember[]>(`/api/organizations/${orgId}/members`, undefined, signal);
  },

};
