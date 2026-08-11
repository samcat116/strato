import { vmsApi } from "@/lib/api/vms";
import { useOrganization } from "@/providers";
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

export const useVM = hooks.useDetail;
export const useVMSnapshots = hooks.useSnapshots;
export const useInvalidateVMs = hooks.useInvalidate;
