/**
 * Human-readable memory size from a raw byte count. The sandbox API returns
 * memory in bytes (unlike the VM DTO, which ships a preformatted string), so the
 * UI formats it client-side.
 */
export function formatMemory(bytes: number): string {
  const gb = bytes / 1024 ** 3;
  if (gb >= 1) {
    return `${Number.isInteger(gb) ? gb : gb.toFixed(1)} GB`;
  }
  const mb = bytes / 1024 ** 2;
  return `${Math.round(mb)} MB`;
}

/**
 * A sandbox's TTL as a duration, e.g. `1h 30m`. Used for the static budget,
 * not the countdown — see `formatRemaining`.
 */
export function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "0s";
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = Math.floor(seconds % 60);

  // Cascading granularity: only ever two units, biggest first, so the value
  // stays glanceable at any scale.
  if (days > 0) return hours > 0 ? `${days}d ${hours}h` : `${days}d`;
  if (hours > 0) return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
  if (minutes > 0) return secs > 0 ? `${minutes}m ${secs}s` : `${minutes}m`;
  return `${secs}s`;
}

/**
 * Time left until `expiresAt`, or null once it has passed — the caller decides
 * how to render an elapsed TTL, since the sweep deletes the sandbox shortly
 * after and the record is about to disappear.
 */
export function formatRemaining(expiresAt: string, now: number = Date.now()): string | null {
  const remainingMs = new Date(expiresAt).getTime() - now;
  if (!Number.isFinite(remainingMs) || remainingMs <= 0) return null;
  return formatDuration(remainingMs / 1000);
}
