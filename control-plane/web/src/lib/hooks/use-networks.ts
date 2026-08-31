import { useQuery, useQueryClient } from "@tanstack/react-query";
import { networksApi } from "@/lib/api/networks";

export function useNetworks(projectId?: string) {
  return useQuery({
    queryKey: ["networks", { projectId: projectId ?? null }],
    queryFn: ({ signal }) =>
      projectId ? networksApi.list(projectId, signal) : Promise.resolve([]),
    // An omitted project means the project provider is still resolving or the
    // selected organization has none. Do not turn that into a fleet-wide read.
    enabled: !!projectId,
  });
}

export function useInvalidateNetworks() {
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: ["networks"] });
}
