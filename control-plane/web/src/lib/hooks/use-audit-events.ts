import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { auditEventsApi, type AuditEventFilters } from "@/lib/api/audit-events";
import { ApiError } from "@/lib/api/client";

// System-admin only; gate callers on user.isSystemAdmin so the query
// doesn't fire (and 403) for regular users. keepPreviousData keeps the
// current page on screen while the next page/filter loads.
export function useAuditEvents(filters: AuditEventFilters, enabled: boolean = true) {
  return useQuery({
    queryKey: ["audit-events", filters],
    queryFn: () => auditEventsApi.list(filters),
    enabled,
    placeholderData: keepPreviousData,
  });
}

export function auditErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof ApiError && error.status === 403) {
    return "You need system administrator rights to view the audit log.";
  }
  return error instanceof Error ? error.message : fallback;
}
