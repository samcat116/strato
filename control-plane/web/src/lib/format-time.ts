type TimeValue = string | number | Date;

function dateFor(value: TimeValue | null | undefined): Date | null {
  if (value === null || value === undefined) return null;
  const date = value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function unformatted(value: TimeValue | null | undefined): string {
  return value === null || value === undefined ? "—" : String(value);
}

export function formatDateTime(
  value: TimeValue | null | undefined,
  options?: Intl.DateTimeFormatOptions
): string {
  return dateFor(value)?.toLocaleString(undefined, options) ?? unformatted(value);
}

export function formatDate(
  value: TimeValue | null | undefined,
  options?: Intl.DateTimeFormatOptions
): string {
  return dateFor(value)?.toLocaleDateString(undefined, options) ?? unformatted(value);
}

export function formatTime(
  value: TimeValue | null | undefined,
  options?: Intl.DateTimeFormatOptions
): string {
  return dateFor(value)?.toLocaleTimeString(undefined, options) ?? unformatted(value);
}

export function formatShortDate(value: TimeValue | null | undefined): string {
  return formatDate(value, {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

export function formatDetailedDateTime(value: TimeValue | null | undefined): string {
  return formatDateTime(value, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

/** A compact relative timestamp such as `4m ago` or `in 42d`. */
export function formatRelative(value?: TimeValue): string {
  if (value === undefined) return "—";
  const then = dateFor(value)?.getTime();
  if (then === undefined) return String(value);

  const deltaMs = then - Date.now();
  const future = deltaMs > 0;
  const absolute = Math.abs(deltaMs);
  const units: Array<[milliseconds: number, suffix: string]> = [
    [86_400_000, "d"],
    [3_600_000, "h"],
    [60_000, "m"],
    [1_000, "s"],
  ];
  const [milliseconds, suffix] =
    units.find(([threshold]) => absolute >= threshold) ?? units.at(-1)!;
  const magnitude = `${Math.round(absolute / milliseconds)}${suffix}`;
  return future ? `in ${magnitude}` : `${magnitude} ago`;
}

/** A compact duration with at most two units, largest first. */
export function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "0s";
  const days = Math.floor(seconds / 86_400);
  const hours = Math.floor((seconds % 86_400) / 3_600);
  const minutes = Math.floor((seconds % 3_600) / 60);
  const remainingSeconds = Math.floor(seconds % 60);

  if (days > 0) return hours > 0 ? `${days}d ${hours}h` : `${days}d`;
  if (hours > 0) return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
  if (minutes > 0) {
    return remainingSeconds > 0
      ? `${minutes}m ${remainingSeconds}s`
      : `${minutes}m`;
  }
  return `${remainingSeconds}s`;
}
