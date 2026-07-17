// Small formatting helpers for the Workload Identity view.

/** Seconds → a compact human TTL, e.g. 3600 → "1h", 1800 → "30m", 45 → "45s". */
export function formatTTL(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "—";
  if (seconds % 3600 === 0) return `${seconds / 3600}h`;
  if (seconds % 60 === 0) return `${seconds / 60}m`;
  if (seconds > 3600) return `${Math.round(seconds / 3600)}h`;
  if (seconds > 60) return `${Math.round(seconds / 60)}m`;
  return `${seconds}s`;
}

/** ISO timestamp → compact relative time (past or future), e.g. "4m ago", "in 42d". */
export function formatRelative(iso?: string): string {
  if (!iso) return "—";
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return "—";
  const deltaMs = then - Date.now();
  const future = deltaMs > 0;
  const abs = Math.abs(deltaMs);
  const units: [number, string][] = [
    [1000, "s"],
    [60_000, "m"],
    [3_600_000, "h"],
    [86_400_000, "d"],
  ];
  let value = Math.round(abs / 1000);
  let suffix = "s";
  for (let i = units.length - 1; i >= 0; i--) {
    const [ms, label] = units[i];
    if (abs >= ms) {
      value = Math.round(abs / ms);
      suffix = label;
      break;
    }
  }
  const magnitude = `${value}${suffix}`;
  return future ? `in ${magnitude}` : `${magnitude} ago`;
}
