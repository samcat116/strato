import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { auditEventsApi, type AuditEventFilters } from "@/lib/api/audit-events";
import { errorMessage } from "@/lib/errors";

// System-admin only; gate callers on user.isSystemAdmin so the query
// doesn't fire (and 403) for regular users. keepPreviousData keeps the
// current page on screen while the next page/filter loads.
export function useAuditEvents(filters: AuditEventFilters, enabled: boolean = true) {
  return useQuery({
    queryKey: ["audit-events", filters],
    queryFn: ({ signal }) => auditEventsApi.list(filters, signal),
    enabled,
    placeholderData: keepPreviousData,
  });
}

export function auditErrorMessage(error: unknown, fallback: string): string {
  return errorMessage(error, fallback, {
    forbidden: "You need system administrator rights to view the audit log.",
  });
}
