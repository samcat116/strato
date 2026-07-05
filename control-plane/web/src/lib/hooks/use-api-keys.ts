import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { apiKeysApi } from "@/lib/api/api-keys";
import type { CreateAPIKeyRequest } from "@/types/api";

export function useAPIKeys() {
  return useQuery({
    queryKey: ["api-keys"],
    queryFn: () => apiKeysApi.list(),
  });
}

export function useCreateAPIKey() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: CreateAPIKeyRequest) => apiKeysApi.create(data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["api-keys"] });
    },
  });
}

export function useRevokeAPIKey() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (id: string) => apiKeysApi.revoke(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["api-keys"] });
    },
  });
}
