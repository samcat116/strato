// OAuth device grant: /activate approval flow + CLI session management

import { api } from "./client";
import type {
  CLISession,
  CredentialRestriction,
  PendingDeviceAuthorization,
} from "@/types/api-contracts";

export const oauthApi = {
  getPendingDevice(userCode: string, signal?: AbortSignal): Promise<PendingDeviceAuthorization> {
    return api.get<PendingDeviceAuthorization>(
      `/api/oauth/device/${encodeURIComponent(userCode)}`, undefined, signal
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

  listSessions(signal?: AbortSignal): Promise<CLISession[]> {
    return api.get<CLISession[]>("/api/oauth/sessions", undefined, signal);
  },

  revokeSession(id: string): Promise<void> {
    return api.delete(`/api/oauth/sessions/${id}`);
  },
};
