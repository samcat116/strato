import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { scimTokensApi } from "@/lib/api/scim-tokens";
import { errorMessage } from "@/lib/errors";
import type {
  CreateSCIMTokenRequest,
  UpdateSCIMTokenRequest,
} from "@/types/api";

export function useSCIMTokens(orgId: string, enabled: boolean = true) {
  return useQuery({
    queryKey: ["scim-tokens", orgId],
    queryFn: ({ signal }) => scimTokensApi.list(orgId, signal),
    enabled: enabled && !!orgId,
  });
}

export function useCreateSCIMToken(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: CreateSCIMTokenRequest) =>
      scimTokensApi.create(orgId, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["scim-tokens", orgId] });
    },
  });
}

export function useUpdateSCIMToken(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      tokenId,
      data,
    }: {
      tokenId: string;
      data: UpdateSCIMTokenRequest;
    }) => scimTokensApi.update(orgId, tokenId, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["scim-tokens", orgId] });
    },
  });
}

export function useDeleteSCIMToken(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (tokenId: string) => scimTokensApi.delete(orgId, tokenId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["scim-tokens", orgId] });
    },
  });
}

export function scimTokenErrorMessage(
  error: unknown,
  fallback: string
): string {
  return errorMessage(error, fallback, {
    forbidden: "You need admin rights to manage SCIM tokens.",
  });
}
