import { afterEach, describe, expect, it, vi } from "vitest";
import { loadFrontendBootstrap } from "./bootstrap-data";

afterEach(() => vi.unstubAllGlobals());

describe("loadFrontendBootstrap", () => {
  it("returns a client fallback when no server API origin is configured", async () => {
    await expect(loadFrontendBootstrap(null, "session=abc")).resolves.toMatchObject({
      source: "client",
      user: null,
    });
  });

  it("treats an unauthenticated session as normal signed-out state", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        Response.json({ reason: "Not authenticated" }, { status: 401 })
      )
    );

    await expect(
      loadFrontendBootstrap("http://control-plane:8080", "session=abc")
    ).resolves.toMatchObject({
      source: "server",
      user: null,
      sessionError: null,
    });
  });

  it("preloads organizations and the active organization's projects", async () => {
    const user = {
      id: "user-1",
      username: "sam",
      email: "sam@example.com",
      displayName: "Sam",
      createdAt: "2026-08-30T00:00:00Z",
      currentOrganizationId: "org-1",
      isSystemAdmin: false,
      source: "local" as const,
    };
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(Response.json({ user }))
      .mockResolvedValueOnce(
        Response.json([
          {
            id: "org-1",
            name: "Example",
            description: "",
            createdAt: "2026-08-30T00:00:00Z",
          },
        ])
      )
      .mockResolvedValueOnce(
        Response.json([
          {
            id: "project-1",
            name: "Platform",
            description: "",
            organizationId: "org-1",
            createdAt: "2026-08-30T00:00:00Z",
            updatedAt: "2026-08-30T00:00:00Z",
          },
        ])
      );
    vi.stubGlobal("fetch", fetchMock);

    const result = await loadFrontendBootstrap(
      "http://control-plane:8080",
      "session=abc"
    );

    expect(result).toMatchObject({
      source: "server",
      user: { id: "user-1" },
      projectOrganizationId: "org-1",
      projects: [{ id: "project-1" }],
    });
    expect(fetchMock).toHaveBeenLastCalledWith(
      new URL("http://control-plane:8080/api/organizations/org-1/projects"),
      expect.objectContaining({ headers: { cookie: "session=abc" } })
    );
  });
});
