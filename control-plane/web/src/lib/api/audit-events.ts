// Audit event API endpoints (read-only trail)

import { api } from "./client";
import type { AuditEventListResponse } from "@/types/api";

export interface AuditEventFilters {
  eventType?: string;
  userID?: string;
  organizationID?: string;
  /** Only events served via the system-admin bypass. */
  adminOnly?: boolean;
  /** ISO8601 timestamps (e.g. 2026-07-09T12:00:00Z). */
  from?: string;
  to?: string;
  limit?: number;
  offset?: number;
}

function toParams(filters: AuditEventFilters): Record<string, string> {
  const params: Record<string, string> = {};
  if (filters.eventType) params.eventType = filters.eventType;
  if (filters.userID) params.userID = filters.userID;
  if (filters.organizationID) params.organizationID = filters.organizationID;
  if (filters.adminOnly) params.adminOnly = "true";
  if (filters.from) params.from = filters.from;
  if (filters.to) params.to = filters.to;
  if (filters.limit !== undefined) params.limit = String(filters.limit);
  if (filters.offset !== undefined) params.offset = String(filters.offset);
  return params;
}

export const auditEventsApi = {
  // System-admin only: the full, cross-organization trail.
  list(filters: AuditEventFilters = {}): Promise<AuditEventListResponse> {
    return api.get<AuditEventListResponse>("/api/audit-events", toParams(filters));
  },

  // Organization admins: events scoped to one organization.
  listForOrganization(
    organizationID: string,
    filters: AuditEventFilters = {}
  ): Promise<AuditEventListResponse> {
    return api.get<AuditEventListResponse>(
      `/api/organizations/${organizationID}/audit-events`,
      toParams(filters)
    );
  },
};
