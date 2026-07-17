import { useQuery, useQueryClient } from "@tanstack/react-query";
import { sandboxesApi } from "@/lib/api/sandboxes";
import { useOrganization } from "@/providers";

export function useSandboxes() {
  const { currentOrg, isLoading: orgLoading } = useOrganization();
  const organizationId = currentOrg?.id;

  return useQuery({
    queryKey: ["sandboxes", { orgId: organizationId ?? null }],
    queryFn: () => sandboxesApi.list(organizationId),
    enabled: !orgLoading,
    refetchInterval: 5000, // Poll every 5 seconds
  });
}

export function useSandbox(id: string) {
  return useQuery({
    queryKey: ["sandboxes", id],
    queryFn: () => sandboxesApi.get(id),
    enabled: !!id,
  });
}

export function useInvalidateSandboxes() {
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: ["sandboxes"] });
}
