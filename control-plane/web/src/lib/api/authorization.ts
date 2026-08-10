// Authorization ("can I?") API endpoint

import { api } from "./client";
import type {
  ActionCheckItem,
  ActionCheckResponse,
} from "@/types/api";

export const authorizationApi = {
  /**
   * Ask the backend which of the canonical action/node checks the caller passes.
   * Returns a map keyed by each check's `key`.
   */
  check(checks: ActionCheckItem[]): Promise<ActionCheckResponse> {
    return api.post<ActionCheckResponse>("/api/authorization/check", {
      checks,
    });
  },
};
