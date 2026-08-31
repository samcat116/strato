// Authorization ("can I?") API endpoint

import { api } from "./client";
import type {
  ActionCheckItem,
  ActionCheckResponse,
} from "@/types/api-contracts";

export const authorizationApi = {
  /**
   * Ask the backend which of the canonical action/node checks the caller passes.
   * Returns a map keyed by each check's `key`.
   */
  check(checks: ActionCheckItem[], signal?: AbortSignal): Promise<ActionCheckResponse> {
    return api.post<ActionCheckResponse>("/api/authorization/check", {
      checks,
    }, signal);
  },

  /** The API caps one decision batch at 50; split larger tables transparently. */
  async checkMany(
    checks: ActionCheckItem[],
    signal?: AbortSignal
  ): Promise<ActionCheckResponse> {
    const batches: ActionCheckItem[][] = [];
    for (let offset = 0; offset < checks.length; offset += 50) {
      batches.push(checks.slice(offset, offset + 50));
    }
    const responses = await Promise.all(
      batches.map((batch) => authorizationApi.check(batch, signal))
    );
    return {
      results: Object.assign({}, ...responses.map((response) => response.results)),
    };
  },
};
