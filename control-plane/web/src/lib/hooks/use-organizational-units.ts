import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { organizationalUnitsApi } from "@/lib/api/organizational-units";
import { ApiError } from "@/lib/api/client";
import type {
  CreateOrganizationalUnitRequest,
  UpdateOrganizationalUnitRequest,
} from "@/types/api";

export function useOrganizationalUnits(orgId: string) {
  return useQuery({
    queryKey: ["organizational-units", orgId],
    queryFn: () => organizationalUnitsApi.list(orgId),
    enabled: !!orgId,
  });
}

export function useOrganizationalUnitTree(
  orgId: string,
  ouId: string | undefined
) {
  return useQuery({
    queryKey: ["organizational-unit-tree", orgId, ouId],
    queryFn: () =>
      ouId
        ? organizationalUnitsApi.tree(orgId, ouId)
        : Promise.reject("No OU ID"),
    enabled: !!orgId && !!ouId,
  });
}

export function useCreateOrganizationalUnit(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: CreateOrganizationalUnitRequest) =>
      organizationalUnitsApi.create(orgId, data),
    onSuccess: () => invalidateOUs(queryClient, orgId),
  });
}

export function useUpdateOrganizationalUnit(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      ouId,
      data,
    }: {
      ouId: string;
      data: UpdateOrganizationalUnitRequest;
    }) => organizationalUnitsApi.update(orgId, ouId, data),
    onSuccess: () => invalidateOUs(queryClient, orgId),
  });
}

export function useDeleteOrganizationalUnit(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (ouId: string) => organizationalUnitsApi.delete(orgId, ouId),
    onSuccess: () => invalidateOUs(queryClient, orgId),
  });
}

// Invalidate both the top-level list and any cached subtrees for this org.
function invalidateOUs(
  queryClient: ReturnType<typeof useQueryClient>,
  orgId: string
) {
  queryClient.invalidateQueries({ queryKey: ["organizational-units", orgId] });
  queryClient.invalidateQueries({
    queryKey: ["organizational-unit-tree", orgId],
  });
}

/**
 * Turns an API error into an OU-management-friendly message. Mutating OU
 * operations require org admin rights (403), and delete is rejected with a
 * 409 when the OU still has child units or projects — both are surfaced
 * verbatim so the user knows what to clean up first.
 */
export function ouErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof ApiError && error.status === 403) {
    return "You need admin rights to manage organizational units.";
  }
  return error instanceof Error ? error.message : fallback;
}
