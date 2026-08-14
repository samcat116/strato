import { beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./client";
import { projectsApi } from "./projects";

vi.mock("./client", () => ({
  api: { post: vi.fn() },
}));

const post = vi.mocked(api.post);

describe("projectsApi.create", () => {
  beforeEach(() => post.mockReset());

  it("creates a project directly beneath its organization", async () => {
    post.mockResolvedValueOnce({});

    await projectsApi.create("org-1", { name: "Platform" });

    expect(post).toHaveBeenCalledWith("/api/organizations/org-1/projects", {
      name: "Platform",
      description: "",
    });
  });

  it("uses the folder-scoped endpoint without duplicating the parent in the body", async () => {
    post.mockResolvedValueOnce({});

    await projectsApi.create("org-1", {
      name: "Platform",
      organizationalUnitId: "folder-1",
    });

    expect(post).toHaveBeenCalledWith(
      "/api/organizations/org-1/ous/folder-1/projects",
      { name: "Platform", description: "" }
    );
  });
});
