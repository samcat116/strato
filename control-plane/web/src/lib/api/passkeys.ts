// Self-service passkey management for the signed-in user.
//
// The add ceremony has its own begin/finish pair (rather than reusing
// /auth/register/*) because the server namespaces its challenges: an
// add-a-passkey challenge is only redeemable here, by the session that
// requested it. Drive it through `webAuthnClient.addPasskey`, which wraps the
// browser credential call around these two requests.

import { api } from "./client";
import type { Passkey } from "@/types/api";
import type { PublicKeyCredentialCreationOptionsJSON } from "@/lib/webauthn/types";

export const passkeysApi = {
  list(): Promise<Passkey[]> {
    return api.get<Passkey[]>("/api/users/me/passkeys");
  },

  addBegin(): Promise<{ options: PublicKeyCredentialCreationOptionsJSON }> {
    return api.post("/api/users/me/passkeys/begin");
  },

  addFinish(data: {
    challenge: string;
    response: unknown;
    name?: string;
    transports?: string[];
  }): Promise<Passkey> {
    return api.post<Passkey>("/api/users/me/passkeys/finish", data);
  },

  rename(id: string, name: string | null): Promise<Passkey> {
    return api.patch<Passkey>(`/api/users/me/passkeys/${id}`, { name });
  },

  delete(id: string): Promise<void> {
    return api.delete(`/api/users/me/passkeys/${id}`);
  },
};
