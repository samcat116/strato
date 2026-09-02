// Small formatting helpers for the Workload Identity view.

export { formatRelative } from "@/lib/format-time";

/** Seconds → a compact human TTL, e.g. 3600 → "1h", 1800 → "30m", 45 → "45s". */
export function formatTTL(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "—";
  if (seconds % 3600 === 0) return `${seconds / 3600}h`;
  if (seconds % 60 === 0) return `${seconds / 60}m`;
  if (seconds > 3600) return `${Math.round(seconds / 3600)}h`;
  if (seconds > 60) return `${Math.round(seconds / 60)}m`;
  return `${seconds}s`;
}
