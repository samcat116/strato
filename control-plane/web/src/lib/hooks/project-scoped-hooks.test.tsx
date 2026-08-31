import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { renderHook, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { networksApi } from "@/lib/api/networks";
import { securityGroupsApi } from "@/lib/api/security-groups";
import { volumesApi } from "@/lib/api/volumes";
import { useNetworks } from "./use-networks";
import { useSecurityGroups } from "./use-security-groups";
import { useVolumes } from "./use-volumes";

vi.mock("@/lib/api/networks", () => ({
  networksApi: { list: vi.fn() },
}));
vi.mock("@/lib/api/security-groups", () => ({
  securityGroupsApi: { list: vi.fn() },
}));
vi.mock("@/lib/api/volumes", () => ({
  volumesApi: {
    list: vi.fn(),
    get: vi.fn(),
    listSnapshots: vi.fn(),
    listProjectSnapshots: vi.fn(),
  },
}));

const listNetworks = vi.mocked(networksApi.list);
const listSecurityGroups = vi.mocked(securityGroupsApi.list);
const listVolumes = vi.mocked(volumesApi.list);

function wrapper({ children }: { children: ReactNode }) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  );
}

describe("project-scoped list hooks", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    listNetworks.mockResolvedValue([]);
    listSecurityGroups.mockResolvedValue([]);
    listVolumes.mockResolvedValue([]);
  });

  it("does not fall back to unscoped reads while no project is selected", () => {
    renderHook(
      () => {
        useNetworks();
        useSecurityGroups();
        useVolumes();
      },
      { wrapper }
    );

    expect(listNetworks).not.toHaveBeenCalled();
    expect(listSecurityGroups).not.toHaveBeenCalled();
    expect(listVolumes).not.toHaveBeenCalled();
  });

  it("loads each resource after a project becomes available", async () => {
    renderHook(
      () => {
        useNetworks("project-1");
        useSecurityGroups("project-1");
        useVolumes("project-1");
      },
      { wrapper }
    );

    await waitFor(() => {
      expect(listNetworks).toHaveBeenCalledWith("project-1", expect.any(AbortSignal));
      expect(listSecurityGroups).toHaveBeenCalledWith(
        "project-1",
        expect.any(AbortSignal)
      );
      expect(listVolumes).toHaveBeenCalledWith(
        "project-1",
        expect.any(AbortSignal)
      );
    });
  });
});
