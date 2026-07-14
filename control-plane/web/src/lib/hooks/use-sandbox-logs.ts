import { useQuery, useQueryClient } from "@tanstack/react-query";
import { sandboxesApi } from "@/lib/api/sandboxes";
import type { SandboxLogsQueryParams } from "@/types/api";

export function useSandboxLogs(
  sandboxId: string,
  params?: SandboxLogsQueryParams
) {
  return useQuery({
    queryKey: ["sandbox-logs", sandboxId, params],
    queryFn: () => sandboxesApi.getLogs(sandboxId, params),
    enabled: !!sandboxId,
    // Poll every 5 seconds when viewing logs
    refetchInterval: 5000,
    // Keep previous data while refetching for smoother UX
    placeholderData: (previousData) => previousData,
  });
}

export function useInvalidateSandboxLogs() {
  const queryClient = useQueryClient();
  return (sandboxId?: string) => {
    if (sandboxId) {
      queryClient.invalidateQueries({ queryKey: ["sandbox-logs", sandboxId] });
    } else {
      queryClient.invalidateQueries({ queryKey: ["sandbox-logs"] });
    }
  };
}
