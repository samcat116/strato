// OAuth device grant: /activate approval flow + CLI session management

import { api } from "./client";
import type {
  CLISession,
  CredentialRestriction,
  PendingDeviceAuthorization,
} from "@/types/api";

export const oauthApi = {
  getPendingDevice(userCode: string): Promise<PendingDeviceAuthorization> {
    return api.get<PendingDeviceAuthorization>(
      `/api/oauth/device/${encodeURIComponent(userCode)}`
    );
  },

  /**
   * Approve a pending device authorization, optionally narrowing what the
   * client asked for. The server refuses anything wider than the request, so
   * this can only ever hand out less (STR-115).
   */
  approveDevice(
    userCode: string,
    restriction?: CredentialRestriction
  ): Promise<void> {
    return api.post(
      `/api/oauth/device/${encodeURIComponent(userCode)}/approve`,
      restriction ? { restriction } : undefined
    );
  },

  denyDevice(userCode: string): Promise<void> {
    return api.post(`/api/oauth/device/${encodeURIComponent(userCode)}/deny`);
  },

  listSessions(): Promise<CLISession[]> {
    return api.get<CLISession[]>("/api/oauth/sessions");
  },

  revokeSession(id: string): Promise<void> {
    return api.delete(`/api/oauth/sessions/${id}`);
  },
};
