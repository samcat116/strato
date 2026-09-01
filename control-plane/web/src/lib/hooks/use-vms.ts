import { vmsApi } from "@/lib/api/vms";
import { useOrganization } from "@/providers";
import { makeResourceQueryHooks } from "./use-resource-queries";

const hooks = makeResourceQueryHooks({
  queryKey: "vms",
  scopeKey: "orgId",
  list: (organizationId, signal) => vmsApi.list(organizationId, signal),
  get: (id, signal) => vmsApi.get(id, signal),
  listSnapshots: (id, signal) => vmsApi.listSnapshots(id, signal),
  listRefetchInterval: 5000, // Poll every 5 seconds
});

export function useVMs() {
  const { currentOrg, isLoading: orgLoading } = useOrganization();
  return hooks.useList(currentOrg?.id, { enabled: !orgLoading });
}

export const useVM = hooks.useDetail;
export const useVMSnapshots = hooks.useSnapshots;
export const useInvalidateVMs = hooks.useInvalidate;
