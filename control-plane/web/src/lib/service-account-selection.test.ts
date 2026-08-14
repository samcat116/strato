import { describe, expect, it } from "vitest";
import type { ServiceAccount } from "@/lib/api/platform-services";
import { selectedServiceAccountForProject } from "./service-account-selection";

const account: ServiceAccount = {
  id: "account-1",
  name: "automation",
  description: "",
  projectId: "project-1",
  projectRoles: ["viewer"],
};

describe("selectedServiceAccountForProject", () => {
  it("returns a selection only when it belongs to the active project", () => {
    expect(
      selectedServiceAccountForProject([account], account.id, "project-1")
    ).toBe(account);
    expect(
      selectedServiceAccountForProject([account], account.id, "project-2")
    ).toBeUndefined();
  });

  it("rejects an account that is absent from the current query result", () => {
    expect(
      selectedServiceAccountForProject([], account.id, "project-1")
    ).toBeUndefined();
  });
});
