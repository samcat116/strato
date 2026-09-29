import { describe, expect, it } from "vitest";
import { pageTitle } from "./nav";

describe("networking navigation", () => {
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
  it("uses the navigation label for physical device inventory", () => {
    expect(pageTitle("/storage/devices")).toBe("Devices");
  });
});
