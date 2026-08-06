// Shared query-string building for the resource log endpoints.

/** The window/paging params every resource's log endpoint accepts. */
export interface LogQueryParams {
  limit?: number;
  direction?: "forward" | "backward";
  start?: number; // Unix timestamp
  end?: number; // Unix timestamp
}

// Returns the "?..." suffix to append to a logs endpoint, or "" when no params
// are set — the endpoints treat an absent param as "server default", so a
// falsy value (limit 0, timestamp 0) is deliberately omitted rather than sent.
export function buildLogQueryString(params?: LogQueryParams): string {
  const searchParams = new URLSearchParams();
  if (params?.limit) searchParams.set("limit", String(params.limit));
  if (params?.direction) searchParams.set("direction", params.direction);
  if (params?.start) searchParams.set("start", String(params.start));
  if (params?.end) searchParams.set("end", String(params.end));

  const query = searchParams.toString();
  return query ? `?${query}` : "";
}
