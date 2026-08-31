const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Normalize a pasted UUID to the form Swift's UUID.uuidString persists. */
export function canonicalVMFilter(value: string): string | undefined {
  const trimmed = value.trim();
  return UUID_PATTERN.test(trimmed) ? trimmed.toUpperCase() : undefined;
}

/** Cached rows must never be presented under a filter/page they did not match. */
export function auditResultsAreCurrent(
  hasInvalidVMFilter: boolean,
  isPlaceholderData: boolean
): boolean {
  return !hasInvalidVMFilter && !isPlaceholderData;
}
