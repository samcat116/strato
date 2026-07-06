import { useQuery } from "@tanstack/react-query";
import { authorizationApi } from "@/lib/api/authorization";
import type { PermissionCheckItem } from "@/types/api";

/**
 * Ask the backend which of `checks` the current user holds, returning a map keyed
 * by each check's `key`. Use it to gate UI (show/hide management controls) instead
 * of hardcoding role assumptions.
 *
 * Missing/loading keys resolve to `false` (fail-closed), so callers can read
 * `perms.manage_project` directly without guarding for undefined.
 */
export function usePermissions(checks: PermissionCheckItem[]) {
  // A stable cache key derived from the checks themselves.
  const key = checks
    .map((c) => `${c.key}:${c.resourceType}:${c.resourceId}:${c.permission}`)
    .sort()
    .join("|");

  const query = useQuery({
    queryKey: ["permissions", key],
    queryFn: () => authorizationApi.check(checks),
    enabled: checks.length > 0 && checks.every((c) => !!c.resourceId),
    staleTime: 30_000,
  });

  const permissions: Record<string, boolean> = {};
  for (const check of checks) {
    permissions[check.key] = query.data?.results[check.key] ?? false;
  }

  return { permissions, isLoading: query.isLoading };
}
