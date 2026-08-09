import { useQuery, useQueryClient } from "@tanstack/react-query";

/**
 * Builds the list/detail/snapshot query hooks and companion invalidator for
 * one resource kind, the same way `makeResourceLogsHooks` does for logs. VMs,
 * sandboxes and volumes differ only in query-key prefix, scope parameter, API
 * object, and list poll interval — the key shapes themselves
 * (`[key, {scope}]`, `[key, id]`, `[key, id, "snapshots"]`) are shared, and
 * cache invalidation (MutationWatcher, the command palette's cache sharing)
 * depends on them staying exactly this way.
 */
export function makeResourceQueryHooks<TResource, TSnapshot>(config: {
  /** Query-key prefix, e.g. "vms" — every key this factory builds starts with it. */
  queryKey: string;
  /** Name of the list key's scope field, e.g. "orgId" or "projectId". */
  scopeKey: string;
  list: (scopeId?: string) => Promise<TResource[]>;
  get: (id: string) => Promise<TResource>;
  listSnapshots: (id: string) => Promise<TSnapshot[]>;
  listRefetchInterval: number;
}) {
  function useList(scopeId?: string, options?: { enabled?: boolean }) {
    return useQuery({
      queryKey: [config.queryKey, { [config.scopeKey]: scopeId ?? null }],
      queryFn: () => config.list(scopeId),
      enabled: options?.enabled,
      refetchInterval: config.listRefetchInterval,
    });
  }

  function useDetail(id: string) {
    return useQuery({
      queryKey: [config.queryKey, id],
      queryFn: () => config.get(id),
      enabled: !!id,
    });
  }

  function useSnapshots(id: string) {
    return useQuery({
      queryKey: [config.queryKey, id, "snapshots"],
      queryFn: () => config.listSnapshots(id),
      enabled: !!id,
      refetchInterval: 5000,
    });
  }

  function useInvalidate() {
    const queryClient = useQueryClient();
    // Prefix match also invalidates per-resource and snapshot queries
    return () => queryClient.invalidateQueries({ queryKey: [config.queryKey] });
  }

  return { useList, useDetail, useSnapshots, useInvalidate };
}
