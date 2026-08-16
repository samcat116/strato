import { describe, expect, it } from "vitest";
import { flattenNav, navTree, pageTitle } from "./nav";

describe("networking navigation", () => {
  it("groups every networking resource under one sidebar section", () => {
    const networking = navTree.find((item) => item.label === "Networking");

    expect(networking?.href).toBeUndefined();
    expect(
      networking?.children?.map(({ label, href }) => ({ label, href }))
    ).toEqual([
      { label: "Networks", href: "/networks" },
      { label: "Load Balancers", href: "/load-balancers" },
      { label: "Floating IPs", href: "/floating-ips" },
      { label: "DNS Zones", href: "/dns-zones" },
      { label: "Security Groups", href: "/security-groups" },
    ]);
  });

  it("does not expose the removed Network Services page", () => {
    expect(flattenNav().some((item) => item.href === "/network-services")).toBe(
      false
    );
  });

  it.each([
    ["/load-balancers", "Load Balancers"],
    ["/floating-ips", "Floating IPs"],
    ["/dns-zones", "DNS Zones"],
    ["/security-groups", "Security Groups"],
  ])("uses the navigation label for %s", (pathname, title) => {
    expect(pageTitle(pathname)).toBe(title);
  });
});

describe("storage navigation", () => {
  it("includes the physical device inventory under Storage", () => {
    const storage = navTree.find((item) => item.label === "Storage");
    expect(storage?.children?.map(({ label, href }) => ({ label, href }))).toContainEqual({
      label: "Devices",
      href: "/storage/devices",
    });
    expect(pageTitle("/storage/devices")).toBe("Devices");
  });
});
