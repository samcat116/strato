import { afterEach, describe, expect, it, vi } from "vitest";
import { api } from "./client";

describe("mutation idempotency headers", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("sends the caller's key and leaves unkeyed mutations as an explicit opt-out", async () => {
    const fetch = vi
      .fn()
      .mockResolvedValue(new Response(undefined, { status: 204 }));
    vi.stubGlobal("fetch", fetch);

    await api.post("/api/vms", { name: "db" }, undefined, "form-key");
    await api.post("/api/vms", { name: "second-intent" });

    expect(new Headers(fetch.mock.calls[0][1]?.headers).get("Idempotency-Key"))
      .toBe("form-key");
    expect(new Headers(fetch.mock.calls[1][1]?.headers).has("Idempotency-Key"))
      .toBe(false);
  });
});
