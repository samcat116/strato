import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { projectMembersApi } from "@/lib/api/project-members";
import { ApiError } from "@/lib/api/client";
import type { ProjectRole } from "@/types/api";

export function useProjectMembers(projectId: string) {
  return useQuery({
    queryKey: ["project-members", projectId],
    queryFn: () => projectMembersApi.list(projectId),
    enabled: !!projectId,
  });
}

/**
 * One lightweight, non-polling inventory request for project IAM management.
 * VM mutation invalidation still refreshes it because its key starts with
 * `vms`, alongside the ordinary VM queries.
 */
export function useProjectVMPrincipals(projectId: string) {
  return useQuery({
    queryKey: ["vms", "project-principals", projectId],
    queryFn: () => projectMembersApi.listVMPrincipals(projectId),
    enabled: !!projectId,
  });
}

/** The one project binding held by a VM's instance identity. */
export function useVMProjectGrant(vmId: string, enabled = true) {
  return useQuery({
    queryKey: ["vm-project-grant", vmId],
    queryFn: () => projectMembersApi.getVMProjectGrant(vmId),
    select: (response) => response.grant,
    enabled: enabled && !!vmId,
  });
}

function useInvalidateMembers(projectId: string) {
  const queryClient = useQueryClient();
  return () =>
    queryClient.invalidateQueries({ queryKey: ["project-members", projectId] });
}

function useInvalidateWorkloadGrants(projectId: string) {
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({
        queryKey: ["project-members", projectId],
      }),
      queryClient.invalidateQueries({ queryKey: ["vm-project-grant"] }),
    ]);
}

export function useGrantProjectMember(projectId: string) {
  const invalidate = useInvalidateMembers(projectId);
  return useMutation({
    mutationFn: ({ userEmail, role }: { userEmail: string; role: ProjectRole }) =>
      projectMembersApi.grant(projectId, userEmail, role),
    onSuccess: invalidate,
  });
}

export function useUpdateProjectMemberRole(projectId: string) {
  const invalidate = useInvalidateMembers(projectId);
  return useMutation({
    mutationFn: ({ userId, role }: { userId: string; role: ProjectRole }) =>
      projectMembersApi.updateRole(projectId, userId, role),
    onSuccess: invalidate,
  });
}

export function useRevokeProjectMember(projectId: string) {
  const invalidate = useInvalidateMembers(projectId);
  return useMutation({
    mutationFn: (userId: string) => projectMembersApi.revoke(projectId, userId),
    onSuccess: invalidate,
  });
}

export function useGrantProjectGroup(projectId: string) {
  const invalidate = useInvalidateMembers(projectId);
  return useMutation({
    mutationFn: ({ groupId, role }: { groupId: string; role: ProjectRole }) =>
      projectMembersApi.grantGroup(projectId, groupId, role),
    onSuccess: invalidate,
  });
}

export function useRevokeProjectGroup(projectId: string) {
  const invalidate = useInvalidateMembers(projectId);
  return useMutation({
    mutationFn: (groupId: string) =>
      projectMembersApi.revokeGroup(projectId, groupId),
    onSuccess: invalidate,
  });
}

export function useSetProjectWorkloadRole(projectId: string) {
  const invalidate = useInvalidateWorkloadGrants(projectId);
  return useMutation({
    mutationFn: ({
      registrationId,
      role,
    }: {
      registrationId: string;
      role: ProjectRole;
    }) => projectMembersApi.grantWorkload(projectId, registrationId, role),
    onSuccess: invalidate,
  });
}

export function useRevokeProjectWorkload(projectId: string) {
  const invalidate = useInvalidateWorkloadGrants(projectId);
  return useMutation({
    mutationFn: (registrationId: string) =>
      projectMembersApi.revokeWorkload(projectId, registrationId),
    onSuccess: invalidate,
  });
}

/** Turns an API error into a project-role-management-friendly message. */
export function projectMemberErrorMessage(
  error: unknown,
  fallback: string
): string {
  if (error instanceof ApiError && error.status === 403) {
    return "You need the project admin role to manage members.";
  }
  return error instanceof Error ? error.message : fallback;
}
