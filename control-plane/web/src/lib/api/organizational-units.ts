// Organizational Unit API endpoints (scoped to an organization)

import { api } from "./client";
import type {
  OrganizationalUnit,
  OrganizationalUnitTree,
  CreateOrganizationalUnitRequest,
  UpdateOrganizationalUnitRequest,
} from "@/types/api";

export const organizationalUnitsApi = {
  /** Top-level OUs for the organization. */
  list(orgId: string): Promise<OrganizationalUnit[]> {
    return api.get<OrganizationalUnit[]>(`/api/organizations/${orgId}/ous`);
  },

  get(orgId: string, ouId: string): Promise<OrganizationalUnit> {
    return api.get<OrganizationalUnit>(
      `/api/organizations/${orgId}/ous/${ouId}`
    );
  },

  /** Full recursive subtree rooted at the given OU. */
  tree(orgId: string, ouId: string): Promise<OrganizationalUnitTree> {
    return api.get<OrganizationalUnitTree>(
      `/api/organizations/${orgId}/ous/${ouId}/tree`
    );
  },

  create(
    orgId: string,
    data: CreateOrganizationalUnitRequest
  ): Promise<OrganizationalUnit> {
    return api.post<OrganizationalUnit>(
      `/api/organizations/${orgId}/ous`,
      data
    );
  },

  update(
    orgId: string,
    ouId: string,
    data: UpdateOrganizationalUnitRequest
  ): Promise<OrganizationalUnit> {
    return api.put<OrganizationalUnit>(
      `/api/organizations/${orgId}/ous/${ouId}`,
      data
    );
  },

  delete(orgId: string, ouId: string): Promise<void> {
    return api.delete(`/api/organizations/${orgId}/ous/${ouId}`);
  },
};
