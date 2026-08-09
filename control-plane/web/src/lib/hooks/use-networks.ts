import { useQuery, useQueryClient } from "@tanstack/react-query";
import { networksApi } from "@/lib/api/networks";

export function useNetworks(projectId?: string) {
  return useQuery({
    queryKey: ["networks", { projectId: projectId ?? null }],
    queryFn: () => networksApi.list(projectId),
  });
}

export function useInvalidateNetworks() {
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: ["networks"] });
}
