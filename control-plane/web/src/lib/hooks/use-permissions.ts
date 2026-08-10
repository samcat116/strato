import { useQuery } from "@tanstack/react-query";
import { authorizationApi } from "@/lib/api/authorization";
import type { ActionCheckItem } from "@/types/api";

/**
 * Ask the backend which of `checks` the current user holds, returning a map keyed
 * by each check's `key`. Use it to gate UI (show/hide management controls) instead
 * of hardcoding role assumptions.
 *
 * Missing/loading keys resolve to `false` (fail-closed), so callers can read
 * `permissions.set_policy` directly without guarding for undefined.
 */
export function usePermissions(checks: ActionCheckItem[]) {
  // A stable cache key derived from the checks themselves.
  const key = checks
    .map((c) => `${c.key}:${c.action}:${c.node.type}:${c.node.id}`)
    .sort()
    .join("|");

  const query = useQuery({
    queryKey: ["permissions", key],
    queryFn: () => authorizationApi.check(checks),
    enabled: checks.length > 0 && checks.every((c) => !!c.node.id),
    staleTime: 30_000,
  });

  const permissions: Record<string, boolean> = {};
  for (const check of checks) {
    permissions[check.key] = query.data?.results[check.key] ?? false;
  }

  return { permissions, isLoading: query.isLoading };
}
