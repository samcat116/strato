import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import ProjectsPage from "./page";

const { projects, usePermissions } = vi.hoisted(() => ({
  projects: [] as Array<Record<string, unknown>>,
  usePermissions: vi.fn(),
}));

vi.mock("@/providers", () => ({
  useAuth: () => ({
    user: { isSystemAdmin: false },
  }),
  useOrganization: () => ({
    organizations: [
      {
        id: "org-1",
        name: "Test Org",
        description: "",
        userRole: "00000000-0000-0000-0000-000000000001",
      },
    ],
    currentOrg: {
      id: "org-1",
      name: "Test Org",
      description: "",
      // Organization roles have been canonical UUIDs since #1128.
      userRole: "00000000-0000-0000-0000-000000000001",
    },
  }),
}));

vi.mock("@/lib/hooks", () => ({
  useProjectsForOrganization: () => ({
    data: projects,
    isLoading: false,
    error: null,
    refetch: vi.fn(),
  }),
  useHierarchy: () => ({
    data: {
      organization: {
        id: "org-1",
        name: "Test Org",
        description: "",
        quotas: [],
        projects: [],
        organizationalUnits: [],
      },
    },
    isLoading: false,
    error: null,
    refetch: vi.fn(),
  }),
  usePermissions,
  useCreateProject: () => ({ isPending: false, mutateAsync: vi.fn() }),
  useUpdateProject: () => ({ isPending: false, mutateAsync: vi.fn() }),
  useDeleteProject: () => ({ isPending: false, mutateAsync: vi.fn() }),
  useTransferProject: () => ({ isPending: false, mutateAsync: vi.fn() }),
}));

function renderProjectsPage() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return render(
    <QueryClientProvider client={queryClient}>
      <ProjectsPage />
    </QueryClientProvider>
  );
}

describe("ProjectsPage permissions", () => {
  afterEach(cleanup);

  beforeEach(() => {
    projects.length = 0;
    usePermissions.mockReturnValue({
      permissions: { create: true },
      isLoading: false,
      error: null,
      refetch: vi.fn(),
    });
  });

  it("shows New Project when the authorization service permits project creation", () => {
    renderProjectsPage();

    expect(
      screen.getByRole("button", { name: "New Project" })
    ).toBeVisible();
  });

  it("allows metadata editing without offering an unauthorized location transfer", () => {
    projects.push({
      id: "project-1",
      name: "Default Project",
      description: "",
      organizationId: "org-1",
      path: "/org-1/project-1",
      defaultEnvironment: "development",
      environments: ["development"],
      vmCount: 0,
    });
    usePermissions.mockReturnValue({
      permissions: {
        create: true,
        update_organization: false,
        "update:project-1": true,
        "transfer:project-1": false,
        "delete:project-1": false,
      },
      isLoading: false,
      error: null,
      refetch: vi.fn(),
    });

    renderProjectsPage();

    fireEvent.click(screen.getByRole("button", { name: "Edit" }));

    expect(screen.getByRole("textbox", { name: "Name" })).toBeEnabled();
    expect(screen.getByRole("combobox", { name: "Location" })).toBeDisabled();
  });

  it("offers only the permitted destructive project actions", async () => {
    projects.push({
      id: "project-1",
      name: "Default Project",
      description: "",
      organizationId: "org-1",
      path: "/org-1/project-1",
      defaultEnvironment: "development",
      environments: ["development"],
      vmCount: 0,
    });
    usePermissions.mockReturnValue({
      permissions: {
        create: true,
        "update:project-1": false,
        "transfer:project-1": true,
        "delete:project-1": false,
      },
      isLoading: false,
      error: null,
      refetch: vi.fn(),
    });

    renderProjectsPage();
    fireEvent.pointerDown(
      screen.getByRole("button", { name: "More actions for Default Project" })
    );

    expect(
      await screen.findByRole("menuitem", { name: "Transfer" })
    ).toBeVisible();
    expect(screen.queryByRole("menuitem", { name: "Delete" })).toBeNull();
  });
});
