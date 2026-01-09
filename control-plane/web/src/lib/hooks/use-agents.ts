import { useQuery, useQueryClient } from "@tanstack/react-query";
import { agentsApi } from "@/lib/api/agents";

export function useAgents() {
  return useQuery({
    queryKey: ["agents"],
    queryFn: agentsApi.list,
    refetchInterval: 10000, // Poll every 10 seconds
  });
}

export function useAgent(id: string) {
  return useQuery({
    queryKey: ["agents", id],
    queryFn: () => agentsApi.get(id),
    enabled: !!id,
  });
}

export function useAgentTokens() {
  return useQuery({
    queryKey: ["agent-tokens"],
    queryFn: agentsApi.listTokens,
  });
}

export function useInvalidateAgents() {
  const queryClient = useQueryClient();
  return () => {
    queryClient.invalidateQueries({ queryKey: ["agents"] });
    queryClient.invalidateQueries({ queryKey: ["agent-tokens"] });
  };
}
