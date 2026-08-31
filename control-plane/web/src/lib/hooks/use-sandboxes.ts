import { sandboxesApi } from "@/lib/api/sandboxes";
import { useOrganization } from "@/providers";
import { makeResourceQueryHooks } from "./use-resource-queries";

const hooks = makeResourceQueryHooks({
  queryKey: "sandboxes",
  scopeKey: "orgId",
  list: (organizationId, signal) => sandboxesApi.list(organizationId, signal),
  get: (id, signal) => sandboxesApi.get(id, signal),
  listSnapshots: (id, signal) => sandboxesApi.listSnapshots(id, signal),
  listRefetchInterval: 5000, // Poll every 5 seconds
});

export function useSandboxes() {
  const { currentOrg, isLoading: orgLoading } = useOrganization();
  return hooks.useList(currentOrg?.id, { enabled: !orgLoading });
}

export const useSandbox = hooks.useDetail;
export const useSandboxSnapshots = hooks.useSnapshots;
export const useInvalidateSandboxes = hooks.useInvalidate;
