// Authorization ("can I?") API endpoint

import { api } from "./client";
import type {
  PermissionCheckItem,
  PermissionCheckResponse,
} from "@/types/api";

export const authorizationApi = {
  /**
   * Ask the backend which of the given permissions the current user holds.
   * Returns a map keyed by each check's `key`.
   */
  check(checks: PermissionCheckItem[]): Promise<PermissionCheckResponse> {
    return api.post<PermissionCheckResponse>("/api/authorization/check", {
      checks,
    });
  },
};
