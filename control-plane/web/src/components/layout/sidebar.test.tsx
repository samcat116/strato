import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { navTree } from "./nav";
import { SidebarSection } from "./sidebar";

let pathname = "/vms";

vi.mock("next/navigation", () => ({
  usePathname: () => pathname,
}));

vi.mock("@/providers", () => ({
  useAuth: () => ({ user: { isSystemAdmin: false } }),
}));

describe("SidebarSection", () => {
  afterEach(() => {
    cleanup();
    pathname = "/vms";
  });

  it("resets a manual collapse after navigation and reveals the active route", () => {
    const compute = navTree.find((item) => item.label === "Compute")!;
    const { rerender } = render(<SidebarSection item={compute} />);

    expect(screen.getByRole("link", { name: "Instances" })).toBeVisible();
    fireEvent.click(screen.getByRole("button", { name: "Collapse Compute" }));
    expect(screen.queryByRole("link", { name: "Instances" })).toBeNull();

    pathname = "/dashboard";
    rerender(<SidebarSection item={compute} />);
    expect(screen.queryByRole("link", { name: "Instances" })).toBeNull();

    pathname = "/vms";
    rerender(<SidebarSection item={compute} />);
    expect(screen.getByRole("link", { name: "Instances" })).toBeVisible();
  });
});
