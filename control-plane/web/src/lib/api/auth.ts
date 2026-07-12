// Auth API endpoints

import { api } from "./client";
import type { ClaimInfoResponse, SessionResponse, User } from "@/types/api";
import type {
  PublicKeyCredentialCreationOptionsJSON,
  PublicKeyCredentialRequestOptionsJSON,
} from "@/lib/webauthn/types";

export const authApi = {
  async getSession(): Promise<SessionResponse | null> {
    try {
      return await api.get<SessionResponse>("/auth/session");
    } catch {
      return null;
    }
  },

  async logout(): Promise<boolean> {
    try {
      await api.post("/auth/logout");
      return true;
    } catch {
      return false;
    }
  },

  // WebAuthn registration - begin
  async registerBegin(username: string): Promise<{ options: PublicKeyCredentialCreationOptionsJSON }> {
    return api.post("/auth/register/begin", { username });
  },

  // WebAuthn registration - finish
  async registerFinish(data: {
    challenge: string;
    response: unknown;
  }): Promise<{ success: boolean; user: User }> {
    return api.post("/auth/register/finish", data);
  },

  // WebAuthn authentication - begin
  async loginBegin(username?: string | null): Promise<{ options: PublicKeyCredentialRequestOptionsJSON }> {
    return api.post("/auth/login/begin", { username });
  },

  // WebAuthn authentication - finish
  async loginFinish(data: {
    challenge: string;
    response: unknown;
  }): Promise<{ success: boolean; user: User }> {
    return api.post("/auth/login/finish", data);
  },

  // Passkey claim (admin-created accounts) - describe the invite
  async claimInfo(token: string): Promise<ClaimInfoResponse> {
    return api.get(`/auth/claim/${encodeURIComponent(token)}`);
  },

  // Passkey claim - begin the ceremony
  async claimBegin(
    token: string
  ): Promise<{ options: PublicKeyCredentialCreationOptionsJSON }> {
    return api.post("/auth/claim/begin", { token });
  },

  // Passkey claim - finish the ceremony (logs the user in)
  async claimFinish(data: {
    token: string;
    challenge: string;
    response: unknown;
  }): Promise<{ success: boolean; user: User }> {
    return api.post("/auth/claim/finish", data);
  },
};
