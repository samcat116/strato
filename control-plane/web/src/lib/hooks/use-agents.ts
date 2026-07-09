import { useQuery, useQueryClient } from "@tanstack/react-query";
import { agentsApi } from "@/lib/api/agents";
import { ApiError } from "@/lib/api/client";

/** Listing agents is system-admin-only; regular users get a 403. */
export function isAgentsForbidden(error: unknown): boolean {
  return error instanceof ApiError && error.status === 403;
}

export function useAgents() {
  return useQuery({
    queryKey: ["agents"],
    queryFn: agentsApi.list,
    // Poll every 10 seconds — but a 403 is permanent for this session, so
    // don't keep hitting a forbidden endpoint.
    refetchInterval: (query) =>
      isAgentsForbidden(query.state.error) ? false : 10000,
    retry: (failureCount, error) =>
      !isAgentsForbidden(error) && failureCount < 1,
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
