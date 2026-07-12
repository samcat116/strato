// OIDC / SSO provider API client.
//
// Management routes live under /api/organizations (unlike SCIM tokens, which
// use the /organizations/:id/settings prefix — the backend registered them
// there first). The lookup route is public: the login page calls it before
// any session exists.
import { api } from "./client";
import type {
  OIDCProvider,
  CreateOIDCProviderRequest,
  UpdateOIDCProviderRequest,
  OIDCProviderTestResult,
  SSOLookupResponse,
} from "@/types/api";

const base = (orgId: string) => `/api/organizations/${orgId}/oidc-providers`;

export const oidcProvidersApi = {
  list(orgId: string): Promise<OIDCProvider[]> {
    return api.get<OIDCProvider[]>(base(orgId));
  },

  create(orgId: string, data: CreateOIDCProviderRequest): Promise<OIDCProvider> {
    return api.post<OIDCProvider>(base(orgId), data);
  },

  update(
    orgId: string,
    providerId: string,
    data: UpdateOIDCProviderRequest
  ): Promise<OIDCProvider> {
    return api.put<OIDCProvider>(`${base(orgId)}/${providerId}`, data);
  },

  delete(orgId: string, providerId: string): Promise<void> {
    return api.delete<void>(`${base(orgId)}/${providerId}`);
  },

  test(orgId: string, providerId: string): Promise<OIDCProviderTestResult> {
    return api.post<OIDCProviderTestResult>(`${base(orgId)}/${providerId}/test`);
  },

  /** Resolve an organization name to its enabled SSO providers (no auth). */
  ssoLookup(organization: string): Promise<SSOLookupResponse> {
    return api.get<SSOLookupResponse>("/api/public/sso/lookup", { organization });
  },

  /**
   * Browser navigation target that starts the OIDC login flow. Relative so it
   * works both behind the production ingress and the Next dev proxy.
   */
  authorizeUrl(orgId: string, providerId: string): string {
    return `/auth/oidc/${orgId}/${providerId}/authorize`;
  },
};
