import { errorMessage } from "@/lib/errors";
import type { Project } from "@/lib/api/projects";
import type { Organization, SessionResponse, User } from "@/types/api";

export type FrontendBootstrap =
  | {
      source: "server";
      user: User | null;
      sessionError: null;
      organizations: Organization[] | null;
      projects: Project[] | null;
      projectOrganizationId: string | null;
    }
  | {
      source: "server";
      user: null;
      sessionError: string;
      organizations: [];
      projects: [];
      projectOrganizationId: null;
    }
  | {
      source: "client";
      user: null;
      sessionError: null;
      organizations: [];
      projects: [];
      projectOrganizationId: null;
    };

class BootstrapRequestError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message);
  }
}

async function fetchBootstrapJSON<T>(
  apiOrigin: string,
  path: string,
  cookie: string
): Promise<T> {
  const response = await fetch(new URL(path, apiOrigin), {
    cache: "no-store",
    headers: cookie ? { cookie } : undefined,
  });

  if (!response.ok) {
    let message = response.statusText || "Request failed";
    try {
      const body = (await response.json()) as { reason?: unknown; error?: unknown };
      if (typeof body.reason === "string") message = body.reason;
      else if (typeof body.error === "string") message = body.error;
    } catch {
      // Keep the status text for non-JSON proxy and startup failures.
    }
    throw new BootstrapRequestError(response.status, message);
  }

  return (await response.json()) as T;
}

function activeOrganizationId(user: User, organizations: Organization[]) {
  if (
    user.currentOrganizationId &&
    organizations.some((organization) => organization.id === user.currentOrganizationId)
  ) {
    return user.currentOrganizationId;
  }
  return organizations[0]?.id ?? null;
}

/**
 * Loads the small request-time state needed to render the shell without the
 * browser's former session -> organizations -> projects waterfall.
 *
 * The caller supplies the runtime control-plane origin and raw Cookie header;
 * keeping those inputs explicit makes this function testable and prevents any
 * server-only value from crossing into the client provider props.
 */
export async function loadFrontendBootstrap(
  apiOrigin: string | null,
  cookie: string
): Promise<FrontendBootstrap> {
  if (!apiOrigin) {
    return {
      source: "client",
      user: null,
      sessionError: null,
      organizations: [],
      projects: [],
      projectOrganizationId: null,
    };
  }

  try {
    const session = await fetchBootstrapJSON<SessionResponse>(apiOrigin, "/auth/session", cookie);

    let organizations: Organization[];
    try {
      organizations = await fetchBootstrapJSON<Organization[]>(
        apiOrigin,
        "/api/organizations",
        cookie
      );
    } catch {
      // Session state is still authoritative. Leave organization data absent
      // so TanStack Query retries it in the browser and renders its normal
      // recoverable loading/error state instead of misclassifying the user.
      return {
        source: "server",
        user: session.user,
        sessionError: null,
        organizations: null,
        projects: null,
        projectOrganizationId: null,
      };
    }

    const organizationId = activeOrganizationId(session.user, organizations);
    let projects: Project[] | null = [];
    if (organizationId) {
      try {
        projects = await fetchBootstrapJSON<Project[]>(
          apiOrigin,
          `/api/organizations/${encodeURIComponent(organizationId)}/projects`,
          cookie
        );
      } catch {
        // As above, an absent initial value asks the existing client query to
        // retry; an empty array would incorrectly mean "this org has none".
        projects = null;
      }
    }

    return {
      source: "server",
      user: session.user,
      sessionError: null,
      organizations,
      projects,
      projectOrganizationId: organizationId,
    };
  } catch (error) {
    if (error instanceof BootstrapRequestError && error.status === 401) {
      return {
        source: "server",
        user: null,
        sessionError: null,
        organizations: [],
        projects: [],
        projectOrganizationId: null,
      };
    }

    return {
      source: "server",
      user: null,
      sessionError:
        errorMessage(error, "Unable to verify your session"),
      organizations: [],
      projects: [],
      projectOrganizationId: null,
    };
  }
}
