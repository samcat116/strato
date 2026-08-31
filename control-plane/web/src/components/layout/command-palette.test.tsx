import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { hierarchyApi } from "@/lib/api/hierarchy";
import { CommandPalette, movePaletteSelection } from "./command-palette";

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn() }),
}));

vi.mock("@/providers", () => ({
  useAuth: () => ({ user: { isSystemAdmin: false } }),
  useOrganization: () => ({
    currentOrg: { id: "org-1", name: "Example" },
    isLoading: false,
  }),
}));

vi.mock("@/lib/api/hierarchy", () => ({
  hierarchyApi: { search: vi.fn() },
}));

const searchHierarchy = vi.mocked(hierarchyApi.search);
let queryClient: QueryClient;

function wrapper({ children }: { children: ReactNode }) {
  return (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  );
}

describe("command palette", () => {
  beforeEach(() => {
    searchHierarchy.mockReset();
    queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    });
  });
  afterEach(cleanup);

  it("never moves keyboard selection outside the available results", () => {
    expect(movePaletteSelection(0, "next", 0)).toBe(0);
    expect(movePaletteSelection(9, "previous", 2)).toBe(0);
    expect(movePaletteSelection(-1, "next", 2)).toBe(1);
    expect(movePaletteSelection(1, "next", 2)).toBe(1);
  });

  it("reports a resource-search failure without hiding page results", async () => {
    searchHierarchy.mockRejectedValue(new Error("Control plane unavailable"));
    render(<CommandPalette />, { wrapper });

    fireEvent.click(screen.getByRole("button", { name: "Open search" }));
    const input = await screen.findByRole("combobox", {
      name: "Search pages and resources",
    });
    fireEvent.change(input, { target: { value: "zz" } });

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Resource search failed"
    );
    expect(screen.getByRole("listbox", { name: "Search results" })).toBeVisible();
    await waitFor(() => expect(searchHierarchy).toHaveBeenCalledOnce());
  });
});
