/**
 * Gravatar helpers.
 *
 * Gravatar's current API keys avatars on the SHA-256 hash of the lowercased,
 * trimmed email address, so no hashing dependency is needed — Web Crypto is
 * enough. `crypto.subtle` is only available in a secure context, so callers
 * must handle a null hash (we simply fall back to initials).
 */

/**
 * Name of the cookie middleware uses to publish the Gravatar setting to the
 * browser, and the env var that drives it.
 *
 * Gravatar lookups send a hash of the user's email to gravatar.com, which some
 * operators of a self-hosted install don't want. The toggle has to be readable
 * at *runtime*: this service ships as a prebuilt image, so a NEXT_PUBLIC_* value
 * inlined at build time couldn't be changed without rebuilding from source.
 * Middleware runs per request and can read the env var — the same reasoning that
 * puts STRATO_API_URL and HSTS in middleware.ts rather than next.config.ts.
 */
export const GRAVATAR_COOKIE = "strato_gravatar";
export const GRAVATAR_ENV_VAR = "STRATO_GRAVATAR_ENABLED";

/** Gravatar is on unless an operator explicitly opts out. */
export function parseGravatarEnabled(raw: string | undefined): boolean {
  if (raw === undefined) return true;
  return !["false", "0", "no", "off"].includes(raw.trim().toLowerCase());
}

/**
 * Read the setting published by middleware. Defaults to enabled when the cookie
 * is missing (no middleware run yet, or a non-browser render).
 */
export function gravatarEnabledFromCookie(cookieString: string): boolean {
  const match = cookieString.match(new RegExp(`(?:^|;\\s*)${GRAVATAR_COOKIE}=([^;]*)`));
  return match ? match[1] !== "0" : true;
}

/** Hash an email for use in a Gravatar URL, or null if hashing isn't available. */
export async function gravatarHash(email: string): Promise<string | null> {
  const normalized = email.trim().toLowerCase();
  if (!normalized || !globalThis.crypto?.subtle) return null;

  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(normalized));
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Build a Gravatar image URL. `d=404` makes Gravatar 404 rather than serve a
 * generated placeholder, which lets the caller fall back to its own initials
 * avatar for users who have no Gravatar.
 */
export function gravatarUrl(hash: string, size: number): string {
  return `https://www.gravatar.com/avatar/${hash}?s=${size}&d=404`;
}
