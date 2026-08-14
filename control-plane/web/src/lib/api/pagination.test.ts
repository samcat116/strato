import { beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./client";
import { listAllPages } from "./pagination";

vi.mock("./client", () => ({
  api: { get: vi.fn() },
}));

const get = vi.mocked(api.get);

describe("listAllPages", () => {
  beforeEach(() => get.mockReset());

  it("drains every server page without dropping rows beyond the first 500", async () => {
    get
      .mockResolvedValueOnce({ items: [1, 2], total: 3, limit: 2, offset: 0 })
      .mockResolvedValueOnce({ items: [3], total: 3, limit: 2, offset: 2 });

    await expect(listAllPages<number>("/api/things", { project_id: "p1" }))
      .resolves.toEqual([1, 2, 3]);
    expect(get).toHaveBeenNthCalledWith(1, "/api/things", {
      project_id: "p1",
      limit: "500",
      offset: "0",
    }, undefined);
    expect(get).toHaveBeenNthCalledWith(2, "/api/things", {
      project_id: "p1",
      limit: "500",
      offset: "2",
    }, undefined);
  });

  it("fails instead of looping forever when pagination stops making progress", async () => {
    get.mockResolvedValue({ items: [], total: 2, limit: 500, offset: 0 });

    await expect(listAllPages("/api/things")).rejects.toThrow(
      "Pagination stalled"
    );
    expect(get).toHaveBeenCalledTimes(1);
  });

  it("passes cancellation through every page request", async () => {
    const controller = new AbortController();
    get.mockResolvedValueOnce({ items: [1], total: 1, limit: 500, offset: 0 });

    await listAllPages<number>("/api/things", {}, controller.signal);

    expect(get).toHaveBeenCalledWith(
      "/api/things",
      { limit: "500", offset: "0" },
      controller.signal
    );
  });
});
