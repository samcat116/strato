import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { organizationsApi } from "@/lib/api/organizations";
import { ApiError } from "@/lib/api/client";

export function useOrganizationMembers(orgId: string) {
  return useQuery({
    queryKey: ["organization-members", orgId],
    queryFn: () => organizationsApi.listMembers(orgId),
    enabled: !!orgId,
  });
}

export function useAddMember(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ userEmail, role }: { userEmail: string; role: string }) =>
      organizationsApi.addMember(orgId, userEmail, role),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["organization-members", orgId],
      });
    },
  });
}

export function useRemoveMember(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (userId: string) =>
      organizationsApi.removeMember(orgId, userId),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["organization-members", orgId],
      });
    },
  });
}

export function useUpdateMemberRole(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ userId, role }: { userId: string; role: string }) =>
      organizationsApi.updateMemberRole(orgId, userId, role),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ["organization-members", orgId],
      });
    },
  });
}

/**
 * Turns an API error into a member-management-friendly message. Surfaces the
 * admin-only authorization semantics (see UserController hardening, #220) as a
 * clear "you need admin rights" message rather than a generic failure.
 */
export function memberErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof ApiError && error.status === 403) {
    return "You need admin rights to manage organization members.";
  }
  return error instanceof Error ? error.message : fallback;
}
