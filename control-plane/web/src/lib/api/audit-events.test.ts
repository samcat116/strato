import { beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./client";
import { auditEventsApi } from "./audit-events";

vi.mock("./client", () => ({
  api: { get: vi.fn() },
}));

const get = vi.mocked(api.get);

describe("auditEventsApi.list", () => {
  beforeEach(() => get.mockReset());

  it("sends both resource predicates for a VM audit query", async () => {
    get.mockResolvedValueOnce({ events: [], total: 0, limit: 50, offset: 0 });

    await auditEventsApi.list({
      resourceType: "vms",
      resourceID: "7C265A66-B4DB-4EB1-82A7-91BF7FC30AE1",
    });

    expect(get).toHaveBeenCalledWith(
      "/api/audit-events",
      {
        resourceType: "vms",
        resourceID: "7C265A66-B4DB-4EB1-82A7-91BF7FC30AE1",
      },
      undefined
    );
  });
});
