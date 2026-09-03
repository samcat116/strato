import { useQuery, useQueryClient } from "@tanstack/react-query";
import { agentsApi } from "@/lib/api/agents";
import { ApiError } from "@/lib/api/client";
import { useInvalidatingMutation } from "@/lib/hooks/use-invalidating-mutation";
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
    queryFn: ({ signal }) => agentsApi.list(organizationId, signal),
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
    queryFn: ({ signal }) => agentsApi.get(id, signal),
    enabled: !!id,
  });
}

// Assigns an agent self-update. The request resolves as soon as the assignment
// is durable (202) — the download, install and restart happen afterwards, and
// show up as `updateDesiredVersion` on the refetched agent.
export function useUpdateAgent() {
  return useInvalidatingMutation(
    ({ id, force }: { id: string; force?: boolean }) =>
      agentsApi.update(id, { force }),
    ({ id }) => [["agents"], ["agents", id]],
  );
}

// Withdraws an agent's update assignment (STR-145).
export function useCancelAgentUpdate() {
  return useInvalidatingMutation(
    ({ id }: { id: string }) => agentsApi.cancelUpdate(id),
    ({ id }) => [["agents"], ["agents", id]],
  );
}

// Toggles declarative auto-update enrollment (issue #434).
export function usePatchAgent() {
  return useInvalidatingMutation(
    ({ id, autoUpdate }: { id: string; autoUpdate: boolean }) =>
      agentsApi.patch(id, { autoUpdate }),
    ({ id }) => [["agents"], ["agents", id]],
  );
}

// Finishes a node's re-identification (STR-98): re-points the workloads this
// agent reports holding off the agent record they are still placed on.
export function useAdoptAgentWorkloads() {
  return useInvalidatingMutation(
    ({ id, fromAgentId }: { id: string; fromAgentId: string }) =>
      agentsApi.adoptWorkloads(id, fromAgentId),
    ({ id }) => [["agents"], ["agents", id], ["vms"]],
  );
}

export function useForceAgentOffline() {
  return useInvalidatingMutation(
    (id: string) => agentsApi.forceOffline(id),
    (id) => [["agents"], ["agents", id]],
  );
}

export function useInvalidateAgents() {
  const queryClient = useQueryClient();
  return () => {
    queryClient.invalidateQueries({ queryKey: ["agents"] });
    queryClient.invalidateQueries({ queryKey: ["agent-enrollments"] });
  };
}
