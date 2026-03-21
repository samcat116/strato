import { useQuery, useQueryClient } from "@tanstack/react-query";
import { vmsApi } from "@/lib/api/vms";
import type { VMLogsQueryParams } from "@/types/api";

export function useVMLogs(vmId: string, params?: VMLogsQueryParams) {
  return useQuery({
    queryKey: ["vm-logs", vmId, params],
    queryFn: () => vmsApi.getLogs(vmId, params),
    enabled: !!vmId,
    // Poll every 5 seconds when viewing logs
    refetchInterval: 5000,
    // Keep previous data while refetching for smoother UX
    placeholderData: (previousData) => previousData,
  });
}

export function useInvalidateVMLogs() {
  const queryClient = useQueryClient();
  return (vmId?: string) => {
    if (vmId) {
      queryClient.invalidateQueries({ queryKey: ["vm-logs", vmId] });
    } else {
      queryClient.invalidateQueries({ queryKey: ["vm-logs"] });
    }
  };
}
