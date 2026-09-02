import { formatDuration } from "@/lib/format-time";

export { formatDuration } from "@/lib/format-time";

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
