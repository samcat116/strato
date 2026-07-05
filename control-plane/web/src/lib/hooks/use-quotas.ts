import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { quotasApi } from "@/lib/api/quotas";
import { ApiError } from "@/lib/api/client";
import type { CreateQuotaRequest, UpdateQuotaRequest } from "@/types/api";

export function useOrganizationQuotas(organizationId: string | undefined) {
  return useQuery({
    queryKey: ["quotas", "organization", organizationId],
    queryFn: () =>
      organizationId
        ? quotasApi.listForOrganization(organizationId)
        : Promise.resolve([]),
    enabled: !!organizationId,
  });
}

export function useProjectQuotas(projectId: string | undefined) {
  return useQuery({
    queryKey: ["quotas", "project", projectId],
    queryFn: () =>
      projectId ? quotasApi.listForProject(projectId) : Promise.resolve([]),
    enabled: !!projectId,
  });
}

export function useInvalidateQuotas() {
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: ["quotas"] });
}

// A quota can be created at one of three scopes; the mutation resolves the
// right endpoint from the target descriptor.
export type QuotaCreateTarget =
  | { scope: "organization"; organizationId: string }
  | { scope: "ou"; organizationId: string; ouId: string }
  | { scope: "project"; projectId: string };

export function useCreateQuota() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      target,
      data,
    }: {
      target: QuotaCreateTarget;
      data: CreateQuotaRequest;
    }) => {
      switch (target.scope) {
        case "organization":
          return quotasApi.createForOrganization(target.organizationId, data);
        case "ou":
          return quotasApi.createForOU(
            target.organizationId,
            target.ouId,
            data
          );
        case "project":
          return quotasApi.createForProject(target.projectId, data);
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["quotas"] });
      queryClient.invalidateQueries({ queryKey: ["hierarchy"] });
    },
  });
}

export function useUpdateQuota() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      quotaId,
      data,
    }: {
      quotaId: string;
      data: UpdateQuotaRequest;
    }) => quotasApi.update(quotaId, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["quotas"] });
      queryClient.invalidateQueries({ queryKey: ["hierarchy"] });
    },
  });
}

export function useDeleteQuota() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (quotaId: string) => quotasApi.delete(quotaId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["quotas"] });
      queryClient.invalidateQueries({ queryKey: ["hierarchy"] });
    },
  });
}

export function quotaErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof ApiError) {
    if (error.status === 403) {
      return "You need admin rights to manage resource quotas.";
    }
    if (error.status === 409) {
      return error.message || "Quota still has active reservations.";
    }
  }
  return error instanceof Error ? error.message : fallback;
}
