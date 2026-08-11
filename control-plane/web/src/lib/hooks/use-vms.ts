import { vmsApi } from "@/lib/api/vms";
import { useOrganization } from "@/providers";
import { useQuery } from "@tanstack/react-query";
import { makeResourceQueryHooks } from "./use-resource-queries";

const hooks = makeResourceQueryHooks({
  queryKey: "vms",
  scopeKey: "orgId",
  list: (organizationId) => vmsApi.list(organizationId),
  get: (id) => vmsApi.get(id),
  listSnapshots: (id) => vmsApi.listSnapshots(id),
  listRefetchInterval: 5000, // Poll every 5 seconds
});

export function useVMs() {
  const { currentOrg, isLoading: orgLoading } = useOrganization();
  return hooks.useList(currentOrg?.id, { enabled: !orgLoading });
}

/** All readable VMs in the displayed project, independent of selected org. */
export function useProjectVMs(projectId: string) {
  return useQuery({
    queryKey: ["vms", { projectId }],
    queryFn: () => vmsApi.listProject(projectId),
    enabled: !!projectId,
    refetchInterval: 5000,
  });
}

export const useVM = hooks.useDetail;
export const useVMSnapshots = hooks.useSnapshots;
export const useInvalidateVMs = hooks.useInvalidate;
