import { useQuery, useQueryClient } from "@tanstack/react-query";
import { vmsApi } from "@/lib/api/vms";
import { useOrganization } from "@/providers";

export function useVMs() {
  const { currentOrg, isLoading: orgLoading } = useOrganization();
  const organizationId = currentOrg?.id;

  return useQuery({
    queryKey: ["vms", { orgId: organizationId ?? null }],
    queryFn: () => vmsApi.list(organizationId),
    enabled: !orgLoading,
    refetchInterval: 5000, // Poll every 5 seconds
  });
}

export function useVM(id: string) {
  return useQuery({
    queryKey: ["vms", id],
    queryFn: () => vmsApi.get(id),
    enabled: !!id,
  });
}

export function useInvalidateVMs() {
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: ["vms"] });
}
