import { useQuery, useQueryClient } from "@tanstack/react-query";

/**
 * Builds the log-polling hook and its companion invalidator for one resource
 * kind. VMs and sandboxes differ only in their query-key prefix, API method,
 * and entry/param types — everything else (polling interval, enabled guard,
 * placeholder data, invalidation semantics) is shared.
 */
export function makeResourceLogsHooks<TParams, TEntry>(
  resourceKey: string,
  getLogs: (id: string, params?: TParams) => Promise<TEntry[]>
) {
  function useLogs(id: string, params?: TParams) {
    return useQuery({
      queryKey: [resourceKey, id, params],
      queryFn: () => getLogs(id, params),
      enabled: !!id,
      // Poll every 5 seconds when viewing logs
      refetchInterval: 5000,
      // Keep previous data while refetching for smoother UX
      placeholderData: (previousData) => previousData,
    });
  }

  function useInvalidateLogs() {
    const queryClient = useQueryClient();
    return (id?: string) => {
      if (id) {
        queryClient.invalidateQueries({ queryKey: [resourceKey, id] });
      } else {
        queryClient.invalidateQueries({ queryKey: [resourceKey] });
      }
    };
  }

  return { useLogs, useInvalidateLogs };
}
