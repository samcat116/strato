// Base API client for making requests to the Vapor backend

export class ApiError extends Error {
  constructor(
    public status: number,
    message: string
  ) {
    super(message);
    this.name = "ApiError";
  }
}

interface FetchOptions extends RequestInit {
  params?: Record<string, string>;
}

// The auth provider probes /auth/session on every page (including /login) to
// hydrate its state, and a 401 there is just the normal signed-out case — so
// auth endpoints and auth pages never trigger a redirect.
function redirectToLoginOnSessionExpiry(endpoint: string) {
  if (typeof window === "undefined") return;
  if (endpoint.startsWith("/auth/")) return;
  const path = window.location.pathname;
  if (path === "/login" || path === "/register") return;
  window.location.assign("/login");
}

export async function apiClient<T>(
  endpoint: string,
  options: FetchOptions = {}
): Promise<T> {
  const { params, ...init } = options;

  let url = endpoint;
  if (params) {
    url += "?" + new URLSearchParams(params).toString();
  }

  const response = await fetch(url, {
    ...init,
    credentials: "include", // Include session cookies
    headers: {
      "Content-Type": "application/json",
      ...init.headers,
    },
  });

  if (!response.ok) {
    let message = "";
    try {
      const error = await response.json();
      if (typeof error.reason === "string") {
        message = error.reason;
      } else if (typeof error.error === "string") {
        message = error.error;
      }
    } catch {
      message = response.statusText;
    }

    if (response.status === 401) {
      redirectToLoginOnSessionExpiry(endpoint);
      throw new ApiError(401, "Your session has expired. Please sign in again.");
    }

    if (response.status === 403) {
      // Vapor's default reason for a bare Abort(.forbidden) is just
      // "Forbidden" — make it read as a permissions problem instead.
      const isGeneric = !message || /^forbidden\.?$/i.test(message);
      throw new ApiError(
        403,
        isGeneric
          ? "You don't have permission to perform this action."
          : message
      );
    }

    throw new ApiError(response.status, message || "Request failed");
  }

  // Handle empty responses (204 No Content, or 200 with an empty body,
  // e.g. Vapor DELETE endpoints that return 200 with content-length: 0)
  if (response.status === 204) {
    return undefined as T;
  }

  const text = await response.text();
  if (text.length === 0) {
    return undefined as T;
  }

  return JSON.parse(text);
}

// Convenience methods
export const api = {
  get<T>(endpoint: string, params?: Record<string, string>): Promise<T> {
    return apiClient<T>(endpoint, { method: "GET", params });
  },

  post<T>(endpoint: string, data?: unknown): Promise<T> {
    return apiClient<T>(endpoint, {
      method: "POST",
      body: data ? JSON.stringify(data) : undefined,
    });
  },

  put<T>(endpoint: string, data?: unknown): Promise<T> {
    return apiClient<T>(endpoint, {
      method: "PUT",
      body: data ? JSON.stringify(data) : undefined,
    });
  },

  patch<T>(endpoint: string, data?: unknown): Promise<T> {
    return apiClient<T>(endpoint, {
      method: "PATCH",
      body: data ? JSON.stringify(data) : undefined,
    });
  },

  delete<T>(endpoint: string): Promise<T> {
    return apiClient<T>(endpoint, { method: "DELETE" });
  },
};
