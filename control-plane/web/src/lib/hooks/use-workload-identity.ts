import { useQuery } from "@tanstack/react-query";
import { workloadIdentityApi } from "@/lib/api/workload-identity";
import { ApiError } from "@/lib/api/client";

// System-admin only; gate callers on user.isSystemAdmin so the query doesn't
// fire (and 403) for regular users. Polls periodically to keep SVID rotation
// and node state reasonably fresh, but backs off once forbidden.
export function useWorkloadIdentity(enabled: boolean = true) {
  return useQuery({
    queryKey: ["workload-identity"],
    queryFn: () => workloadIdentityApi.overview(),
    enabled,
    refetchInterval: (query) =>
      isWorkloadIdentityForbidden(query.state.error) ? false : 30000,
    retry: (count, error) => !isWorkloadIdentityForbidden(error) && count < 1,
  });
}

export function isWorkloadIdentityForbidden(error: unknown): boolean {
  return error instanceof ApiError && error.status === 403;
}

export function workloadIdentityErrorMessage(error: unknown, fallback: string): string {
  if (isWorkloadIdentityForbidden(error)) {
    return "You need system administrator rights to view workload identity.";
  }
  return error instanceof Error ? error.message : fallback;
}
