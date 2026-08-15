import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TransferProjectDialog } from "./transfer-project-dialog";

vi.mock("@/providers", () => ({
  useOrganization: () => ({
    currentOrg: {
      id: "org-1",
      name: "Source Org",
      description: "",
      userRole: "00000000-0000-0000-0000-000000000001",
    },
    organizations: [
      {
        id: "org-1",
        name: "Source Org",
        description: "",
        userRole: "00000000-0000-0000-0000-000000000001",
      },
      {
        id: "org-2",
        name: "Destination Org",
        description: "",
        userRole: "00000000-0000-0000-0000-000000000001",
      },
    ],
  }),
}));

vi.mock("@/lib/hooks", () => ({
  usePermissions: () => ({
    permissions: { "destination:org-2": true },
  }),
  useTransferProject: () => ({
    isPending: false,
    mutateAsync: vi.fn(),
  }),
}));

describe("TransferProjectDialog permissions", () => {
  afterEach(cleanup);

  it("offers a destination allowed by the authorization service", () => {
    render(
      <TransferProjectDialog
        open
        onOpenChange={vi.fn()}
        project={{
          id: "project-1",
          name: "Default Project",
          description: "",
          organizationId: "org-1",
          path: "/org-1/project-1",
          defaultEnvironment: "development",
          environments: ["development"],
          vmCount: 0,
        }}
      />
    );

    expect(screen.getByRole("combobox")).toBeVisible();
    expect(
      screen.queryByText("No other organizations are available to transfer to.")
    ).toBeNull();
  });
});
