import { useQuery, useQueryClient } from "@tanstack/react-query";
import { vmsApi } from "@/lib/api/vms";

export function useVMs() {
  return useQuery({
    queryKey: ["vms"],
    queryFn: vmsApi.list,
    refetchInterval: 5000, // Poll every 5 seconds
  });
}

export function useVM(id: string) {
  return useQuery({
    queryKey: ["vms", id],
    queryFn: () => vmsApi.get(id),
    enabled: !!id,
  });
}

export function useInvalidateVMs() {
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: ["vms"] });
}
