import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { oidcProvidersApi } from "@/lib/api/oidc-providers";
import { ApiError } from "@/lib/api/client";
import type {
  CreateOIDCProviderRequest,
  UpdateOIDCProviderRequest,
} from "@/types/api";

export function useOIDCProviders(orgId: string, enabled = true) {
  return useQuery({
    queryKey: ["oidc-providers", orgId],
    queryFn: () => oidcProvidersApi.list(orgId),
    enabled: enabled && !!orgId,
  });
}

export function useCreateOIDCProvider(orgId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (data: CreateOIDCProviderRequest) =>
      oidcProvidersApi.create(orgId, data),
    onSuccess: () =>
      queryClient.invalidateQueries({ queryKey: ["oidc-providers", orgId] }),
  });
}

export function useUpdateOIDCProvider(orgId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      providerId,
      data,
    }: {
      providerId: string;
      data: UpdateOIDCProviderRequest;
    }) => oidcProvidersApi.update(orgId, providerId, data),
    onSuccess: () =>
      queryClient.invalidateQueries({ queryKey: ["oidc-providers", orgId] }),
  });
}

export function useDeleteOIDCProvider(orgId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (providerId: string) =>
      oidcProvidersApi.delete(orgId, providerId),
    onSuccess: () =>
      queryClient.invalidateQueries({ queryKey: ["oidc-providers", orgId] }),
  });
}

export function useTestOIDCProvider(orgId: string) {
  return useMutation({
    mutationFn: (providerId: string) => oidcProvidersApi.test(orgId, providerId),
  });
}

export function oidcProviderErrorMessage(
  error: unknown,
  fallback: string
): string {
  if (error instanceof ApiError && error.status === 403) {
    return "You need admin rights to manage SSO providers.";
  }
  return error instanceof Error ? error.message : fallback;
}
