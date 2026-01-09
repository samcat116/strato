// Auth API endpoints

import { api } from "./client";
import type { SessionResponse, User } from "@/types/api";
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
};
