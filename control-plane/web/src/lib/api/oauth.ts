// OAuth device grant: /activate approval flow + CLI session management

import { api } from "./client";
import type { CLISession, PendingDeviceAuthorization } from "@/types/api";

export const oauthApi = {
  getPendingDevice(userCode: string): Promise<PendingDeviceAuthorization> {
    return api.get<PendingDeviceAuthorization>(
      `/api/oauth/device/${encodeURIComponent(userCode)}`
    );
  },

  approveDevice(userCode: string): Promise<void> {
    return api.post(`/api/oauth/device/${encodeURIComponent(userCode)}/approve`);
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
