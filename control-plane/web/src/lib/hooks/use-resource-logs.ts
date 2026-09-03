import { useQuery } from "@tanstack/react-query";

/**
 * Builds the log-polling hook for one resource
 * kind. VMs and sandboxes differ only in their query-key prefix, API method,
 * and entry/param types — everything else is shared.
 */
export function makeResourceLogsHooks<TParams, TEntry>(
  resourceKey: string,
  getLogs: (id: string, params?: TParams, signal?: AbortSignal) => Promise<TEntry[]>
) {
  function useLogs(id: string, params?: TParams, pollingEnabled = true) {
    return useQuery({
      queryKey: [resourceKey, id, params],
      queryFn: ({ signal }) => getLogs(id, params, signal),
      enabled: !!id,
      refetchInterval: pollingEnabled ? 5000 : false,
      // Keep previous data while refetching for smoother UX
      placeholderData: (previousData) => previousData,
    });
  }

  return useLogs;
}
