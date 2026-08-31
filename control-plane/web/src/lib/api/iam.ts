// IAM endpoints: roles, authored policies, and the action catalog.

import { api } from "./client";
import type {
  IAMActionCatalogResponse,
  IAMBindableRolesResponse,
  IAMNodeType,
  IAMPolicy,
  IAMPolicyCreateRequest,
  IAMPolicyListResponse,
  IAMPolicyUpdateRequest,
  IAMPolicyValidateRequest,
  IAMPolicyValidateResponse,
  IAMRole,
  IAMRoleCreateRequest,
  IAMRoleListResponse,
  IAMRoleOwnerType,
  IAMRoleUpdateRequest,
  IAMRoleValidateRequest,
  IAMRoleValidateResponse,
} from "@/types/api-contracts";

export const iamApi = {
  // Roles
  listRoles(
    ownerType: IAMRoleOwnerType,
    ownerId: string,
    signal?: AbortSignal
  ): Promise<IAMRoleListResponse> {
    return api.get<IAMRoleListResponse>("/api/iam/roles", {
      ownerType,
      ownerId,
    }, signal);
  },

  listBindableRoles(
    nodeType: IAMNodeType,
    nodeId: string,
    signal?: AbortSignal
  ): Promise<IAMBindableRolesResponse> {
    return api.get<IAMBindableRolesResponse>("/api/iam/roles/bindable", {
      nodeType,
      nodeId,
    }, signal);
  },

  createRole(data: IAMRoleCreateRequest): Promise<IAMRole> {
    return api.post<IAMRole>("/api/iam/roles", data);
  },

  updateRole(roleId: string, data: IAMRoleUpdateRequest): Promise<IAMRole> {
    return api.patch<IAMRole>(`/api/iam/roles/${roleId}`, data);
  },

  deleteRole(roleId: string): Promise<void> {
    return api.delete(`/api/iam/roles/${roleId}`);
  },

  validateRole(
    data: IAMRoleValidateRequest
  ): Promise<IAMRoleValidateResponse> {
    return api.post<IAMRoleValidateResponse>("/api/iam/roles/validate", data);
  },

  // Action catalog
  listActions(signal?: AbortSignal): Promise<IAMActionCatalogResponse> {
    return api.get<IAMActionCatalogResponse>("/api/iam/actions", undefined, signal);
  },

  // Authored policies
  listPolicies(
    ownerType: IAMRoleOwnerType,
    ownerId: string,
    signal?: AbortSignal
  ): Promise<IAMPolicyListResponse> {
    return api.get<IAMPolicyListResponse>("/api/iam/policies", {
      ownerType,
      ownerId,
    }, signal);
  },

  createPolicy(data: IAMPolicyCreateRequest): Promise<IAMPolicy> {
    return api.post<IAMPolicy>("/api/iam/policies", data);
  },

  updatePolicy(
    policyId: string,
    data: IAMPolicyUpdateRequest
  ): Promise<IAMPolicy> {
    return api.patch<IAMPolicy>(`/api/iam/policies/${policyId}`, data);
  },

  deletePolicy(policyId: string): Promise<void> {
    return api.delete(`/api/iam/policies/${policyId}`);
  },

  validatePolicy(
    data: IAMPolicyValidateRequest
  ): Promise<IAMPolicyValidateResponse> {
    return api.post<IAMPolicyValidateResponse>(
      "/api/iam/policies/validate",
      data
    );
  },
};
