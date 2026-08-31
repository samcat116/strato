const DEFAULT_POST_LOGIN_PATH = "/dashboard";
const POST_LOGIN_STORAGE_KEY = "strato.postLoginPath";

/**
 * Accept only same-origin application paths. In particular, reject protocol-
 * relative URLs (`//host`) so a `next` query parameter can never become an
 * open redirect after authentication.
 */
export function safePostLoginPath(candidate: string | null | undefined): string {
  if (!candidate || !candidate.startsWith("/") || candidate.startsWith("//")) {
    return DEFAULT_POST_LOGIN_PATH;
  }

  try {
    const parsed = new URL(candidate, "https://strato.invalid");
    if (parsed.origin !== "https://strato.invalid") {
      return DEFAULT_POST_LOGIN_PATH;
    }

    // Authentication entry points are never useful return destinations and
    // would create a redirect loop for an already-authenticated user.
    if (["/login", "/register", "/claim"].includes(parsed.pathname)) {
      return DEFAULT_POST_LOGIN_PATH;
    }

    return `${parsed.pathname}${parsed.search}${parsed.hash}`;
  } catch {
    return DEFAULT_POST_LOGIN_PATH;
  }
}

export function loginHrefFor(candidate: string): string {
  return `/login?next=${encodeURIComponent(safePostLoginPath(candidate))}`;
}

export function rememberPostLoginPath(candidate: string): void {
  if (typeof window === "undefined") return;
  try {
    window.sessionStorage.setItem(
      POST_LOGIN_STORAGE_KEY,
      safePostLoginPath(candidate)
    );
  } catch {
    // Storage can be unavailable in hardened/private browser contexts. The
    // normal query-parameter path still works for passkey sign-in.
  }
}

export function resolvePostLoginPath(
  candidate?: string | null,
  consumeStored = false
): string {
  if (typeof window === "undefined") return safePostLoginPath(candidate);

  try {
    if (candidate) {
      if (consumeStored) {
        window.sessionStorage.removeItem(POST_LOGIN_STORAGE_KEY);
      }
      return safePostLoginPath(candidate);
    }
    const stored = window.sessionStorage.getItem(POST_LOGIN_STORAGE_KEY);
    if (consumeStored) {
      window.sessionStorage.removeItem(POST_LOGIN_STORAGE_KEY);
    }
    return safePostLoginPath(stored);
  } catch {
    return DEFAULT_POST_LOGIN_PATH;
  }
}
