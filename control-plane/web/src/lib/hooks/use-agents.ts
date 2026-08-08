import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { agentsApi } from "@/lib/api/agents";
import { ApiError } from "@/lib/api/client";
import { useOrganization } from "@/providers";

/** Listing agents is system-admin-only; regular users get a 403. */
export function isAgentsForbidden(error: unknown): boolean {
  return error instanceof ApiError && error.status === 403;
}

export function useAgents() {
  const { currentOrg, isLoading: orgLoading } = useOrganization();
  const organizationId = currentOrg?.id;

  return useQuery({
    // The org id belongs in the key, not just the request: it makes an org
    // switch refetch on its own, rather than relying on switchOrg remembering
    // to invalidate this query.
    queryKey: ["agents", { orgId: organizationId ?? null }],
    queryFn: () => agentsApi.list(organizationId),
    // Wait for org resolution so the first fetch is already scoped — an
    // unscoped fetch would flash the whole fleet before narrowing.
    enabled: !orgLoading,
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

// Assigns an agent self-update. The request resolves as soon as the assignment
// is durable (202) — the download, install and restart happen afterwards, and
// show up as `updateDesiredVersion` on the refetched agent.
export function useUpdateAgent() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id, force }: { id: string; force?: boolean }) =>
      agentsApi.update(id, { force }),
    onSuccess: (_result, { id }) => {
      queryClient.invalidateQueries({ queryKey: ["agents"] });
      queryClient.invalidateQueries({ queryKey: ["agents", id] });
    },
  });
}

// Withdraws an agent's update assignment (STR-145).
export function useCancelAgentUpdate() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id }: { id: string }) => agentsApi.cancelUpdate(id),
    onSuccess: (_result, { id }) => {
      queryClient.invalidateQueries({ queryKey: ["agents"] });
      queryClient.invalidateQueries({ queryKey: ["agents", id] });
    },
  });
}

// Toggles declarative auto-update enrollment (issue #434).
export function usePatchAgent() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id, autoUpdate }: { id: string; autoUpdate: boolean }) =>
      agentsApi.patch(id, { autoUpdate }),
    onSuccess: (_result, { id }) => {
      queryClient.invalidateQueries({ queryKey: ["agents"] });
      queryClient.invalidateQueries({ queryKey: ["agents", id] });
    },
  });
}

// Finishes a node's re-identification (STR-98): re-points the workloads this
// agent reports holding off the agent record they are still placed on.
export function useAdoptAgentWorkloads() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id, fromAgentId }: { id: string; fromAgentId: string }) =>
      agentsApi.adoptWorkloads(id, fromAgentId),
    onSuccess: (_result, { id }) => {
      queryClient.invalidateQueries({ queryKey: ["agents"] });
      queryClient.invalidateQueries({ queryKey: ["agents", id] });
      queryClient.invalidateQueries({ queryKey: ["vms"] });
    },
  });
}

export function useInvalidateAgents() {
  const queryClient = useQueryClient();
  return () => {
    queryClient.invalidateQueries({ queryKey: ["agents"] });
    queryClient.invalidateQueries({ queryKey: ["agent-enrollments"] });
  };
}
