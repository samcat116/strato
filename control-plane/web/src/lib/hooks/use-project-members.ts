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

function useInvalidateMembers(projectId: string) {
  const queryClient = useQueryClient();
  return () =>
    queryClient.invalidateQueries({ queryKey: ["project-members", projectId] });
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
