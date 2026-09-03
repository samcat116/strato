import { beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./client";
import { authorizationApi } from "./authorization";
import type { ActionCheckItem } from "@/types/api";

vi.mock("./client", () => ({
  api: { post: vi.fn() },
}));

const post = vi.mocked(api.post);

describe("authorizationApi.checkMany", () => {
  beforeEach(() => post.mockReset());

  it("chunks large resource tables to the API's 50-check limit", async () => {
    const checks: ActionCheckItem[] = Array.from({ length: 51 }, (_, index) => ({
      key: `check-${index}`,
      action: "vm:read",
      node: { type: "virtual_machine", id: `id-${index}` },
    }));
    post
      .mockResolvedValueOnce({ results: { "check-0": true } })
      .mockResolvedValueOnce({ results: { "check-50": false } });

    await expect(authorizationApi.checkMany(checks)).resolves.toEqual({
      results: { "check-0": true, "check-50": false },
    });
    expect(post).toHaveBeenCalledTimes(2);
    expect(post.mock.calls[0][1]).toEqual({ checks: checks.slice(0, 50) });
    expect(post.mock.calls[1][1]).toEqual({ checks: checks.slice(50) });
  });
});
