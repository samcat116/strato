import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { groupsApi } from "@/lib/api/groups";
import { ApiError } from "@/lib/api/client";
import type { CreateGroupRequest, UpdateGroupRequest } from "@/types/api";

export function useGroups(orgId: string) {
  return useQuery({
    queryKey: ["organization-groups", orgId],
    queryFn: () => groupsApi.list(orgId),
    enabled: !!orgId,
  });
}

export function useGroupMembers(orgId: string, groupId: string | undefined) {
  return useQuery({
    queryKey: ["group-members", orgId, groupId],
    queryFn: () =>
      groupId ? groupsApi.listMembers(orgId, groupId) : Promise.resolve([]),
    enabled: !!orgId && !!groupId,
  });
}

export function useCreateGroup(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: CreateGroupRequest) => groupsApi.create(orgId, data),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["organization-groups", orgId],
      });
    },
  });
}

export function useUpdateGroup(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      groupId,
      data,
    }: {
      groupId: string;
      data: UpdateGroupRequest;
    }) => groupsApi.update(orgId, groupId, data),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["organization-groups", orgId],
      });
    },
  });
}

export function useDeleteGroup(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (groupId: string) => groupsApi.delete(orgId, groupId),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["organization-groups", orgId],
      });
    },
  });
}

export function useAddGroupMembers(orgId: string, groupId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (userIds: string[]) =>
      groupsApi.addMembers(orgId, groupId, userIds),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["group-members", orgId, groupId],
      });
      queryClient.invalidateQueries({
        queryKey: ["organization-groups", orgId],
      });
    },
  });
}

export function useRemoveGroupMember(orgId: string, groupId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (userId: string) =>
      groupsApi.removeMember(orgId, groupId, userId),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["group-members", orgId, groupId],
      });
      queryClient.invalidateQueries({
        queryKey: ["organization-groups", orgId],
      });
    },
  });
}

/**
 * Turns an API error into a group-management-friendly message. The backend
 * requires org admin rights for all mutating group operations, so a 403 is
 * surfaced as a clear authorization message rather than a generic failure.
 */
export function groupErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof ApiError && error.status === 403) {
    return "You need admin rights to manage groups.";
  }
  return error instanceof Error ? error.message : fallback;
}
