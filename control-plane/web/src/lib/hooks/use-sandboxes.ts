import { useQuery, useQueryClient } from "@tanstack/react-query";
import { sandboxesApi } from "@/lib/api/sandboxes";

export function useSandboxes() {
  return useQuery({
    queryKey: ["sandboxes"],
    queryFn: sandboxesApi.list,
    refetchInterval: 5000, // Poll every 5 seconds
  });
}

export function useSandbox(id: string) {
  return useQuery({
    queryKey: ["sandboxes", id],
    queryFn: () => sandboxesApi.get(id),
    enabled: !!id,
  });
}

export function useInvalidateSandboxes() {
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: ["sandboxes"] });
}
