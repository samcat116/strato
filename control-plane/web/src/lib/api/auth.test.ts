import { afterEach, describe, expect, it, vi } from "vitest";
import { authApi } from "./auth";
import { ApiError } from "./client";

describe("authApi.getSession", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("treats a 401 as the normal signed-out state", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ reason: "Unauthorized" }), {
          status: 401,
          headers: { "Content-Type": "application/json" },
        })
      )
    );

    await expect(authApi.getSession()).resolves.toBeNull();
  });

  it("does not turn a control-plane outage into a logout", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ reason: "Service unavailable" }), {
          status: 503,
          headers: { "Content-Type": "application/json" },
        })
      )
    );

    await expect(authApi.getSession()).rejects.toEqual(
      expect.objectContaining<Partial<ApiError>>({
        name: "ApiError",
        status: 503,
      })
    );
  });
});
