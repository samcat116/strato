import { useQuery, useQueryClient } from "@tanstack/react-query";
import { sitesApi } from "@/lib/api/sites";
import { useOrganization } from "@/providers";

export function useSites() {
  const { currentOrg, isLoading: orgLoading } = useOrganization();
  const organizationId = currentOrg?.id;

  return useQuery({
    queryKey: ["sites", { orgId: organizationId ?? null }],
    queryFn: () => sitesApi.list(organizationId),
    enabled: !orgLoading,
  });
}

export function useInvalidateSites() {
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: ["sites"] });
}
