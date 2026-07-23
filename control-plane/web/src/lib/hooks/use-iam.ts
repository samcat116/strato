import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { iamApi } from "@/lib/api/iam";
import { ApiError } from "@/lib/api/client";
import type {
  IAMNode,
  IAMPolicyCreateRequest,
  IAMPolicyUpdateRequest,
  IAMPolicyValidateRequest,
  IAMRoleCreateRequest,
  IAMRoleOwnerType,
  IAMRoleUpdateRequest,
  IAMRoleValidateRequest,
} from "@/types/api";

// ---- Roles ----

export function useRoles(ownerType: IAMRoleOwnerType, ownerId: string) {
  return useQuery({
    queryKey: ["iam-roles", ownerType, ownerId],
    queryFn: () => iamApi.listRoles(ownerType, ownerId),
    enabled: !!ownerId,
    select: (data) => data.roles,
  });
}

export function useCreateRole(ownerType: IAMRoleOwnerType, ownerId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (data: IAMRoleCreateRequest) => iamApi.createRole(data),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["iam-roles", ownerType, ownerId],
      });
    },
  });
}

export function useUpdateRole(ownerType: IAMRoleOwnerType, ownerId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      roleId,
      data,
    }: {
      roleId: string;
      data: IAMRoleUpdateRequest;
    }) => iamApi.updateRole(roleId, data),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["iam-roles", ownerType, ownerId],
      });
    },
  });
}

export function useDeleteRole(ownerType: IAMRoleOwnerType, ownerId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (roleId: string) => iamApi.deleteRole(roleId),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["iam-roles", ownerType, ownerId],
      });
    },
  });
}

export function useValidateRole() {
  return useMutation({
    mutationFn: (data: IAMRoleValidateRequest) => iamApi.validateRole(data),
  });
}

/** The roles bindable on a tree node — platform defaults plus everything owned
 *  along the node's ancestor chain. `node` may be null while it resolves. */
export function useBindableRoles(node: IAMNode | null | undefined) {
  return useQuery({
    queryKey: ["iam-bindable-roles", node?.type, node?.id],
    queryFn: () =>
      node
        ? iamApi.listBindableRoles(node.type, node.id)
        : Promise.reject(new Error("no node")),
    enabled: !!node?.id,
    select: (data) => data.roles,
  });
}

// ---- Action catalog ----

export function useActionCatalog() {
  return useQuery({
    queryKey: ["iam-actions"],
    queryFn: () => iamApi.listActions(),
    select: (data) => data.services,
    // The catalog describes the software, not any deployment's policy, so it
    // never changes within a session.
    staleTime: Infinity,
  });
}

// ---- Authored policies ----

export function usePolicies(ownerType: IAMRoleOwnerType, ownerId: string) {
  return useQuery({
    queryKey: ["iam-policies", ownerType, ownerId],
    queryFn: () => iamApi.listPolicies(ownerType, ownerId),
    enabled: !!ownerId,
    select: (data) => data.policies,
  });
}

export function useCreatePolicy(ownerType: IAMRoleOwnerType, ownerId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (data: IAMPolicyCreateRequest) => iamApi.createPolicy(data),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["iam-policies", ownerType, ownerId],
      });
    },
  });
}

export function useUpdatePolicy(ownerType: IAMRoleOwnerType, ownerId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      policyId,
      data,
    }: {
      policyId: string;
      data: IAMPolicyUpdateRequest;
    }) => iamApi.updatePolicy(policyId, data),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["iam-policies", ownerType, ownerId],
      });
    },
  });
}

export function useDeletePolicy(ownerType: IAMRoleOwnerType, ownerId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (policyId: string) => iamApi.deletePolicy(policyId),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["iam-policies", ownerType, ownerId],
      });
    },
  });
}

export function useValidatePolicy() {
  return useMutation({
    mutationFn: (data: IAMPolicyValidateRequest) => iamApi.validatePolicy(data),
  });
}

/**
 * Turns an API error into an IAM-management-friendly message. Writes require
 * admin rights on the owning node, so a 403 is surfaced as an authorization
 * message; the backend's 409 (a role still has active bindings, or a name
 * clash) and 400 (Cedar shape/compile errors) already carry useful reasons.
 */
export function iamErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof ApiError && error.status === 403) {
    return "You need admin rights on this organization or project to manage roles and policies.";
  }
  return error instanceof Error ? error.message : fallback;
}
