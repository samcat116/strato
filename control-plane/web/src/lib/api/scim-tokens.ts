// SCIM provisioning token endpoints (scoped to an organization)
//
// Note: these routes live under /organizations (not /api) on the backend;
// both the dev rewrites (next.config.ts) and the production proxies route
// /organizations/* to the control plane.

import { api } from "./client";
import type {
  SCIMToken,
  CreateSCIMTokenRequest,
  CreateSCIMTokenResponse,
  UpdateSCIMTokenRequest,
} from "@/types/api";

export const scimTokensApi = {
  list(orgId: string): Promise<SCIMToken[]> {
    return api.get<SCIMToken[]>(
      `/organizations/${orgId}/settings/scim-tokens`
    );
  },

  create(
    orgId: string,
    data: CreateSCIMTokenRequest
  ): Promise<CreateSCIMTokenResponse> {
    return api.post<CreateSCIMTokenResponse>(
      `/organizations/${orgId}/settings/scim-tokens`,
      data
    );
  },

  update(
    orgId: string,
    tokenId: string,
    data: UpdateSCIMTokenRequest
  ): Promise<SCIMToken> {
    return api.patch<SCIMToken>(
      `/organizations/${orgId}/settings/scim-tokens/${tokenId}`,
      data
    );
  },

  delete(orgId: string, tokenId: string): Promise<void> {
    return api.delete(`/organizations/${orgId}/settings/scim-tokens/${tokenId}`);
  },
};
