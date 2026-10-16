import { expect, test, type Page } from "@playwright/test";

test.use({ locale: "en-US", timezoneId: "UTC" });

async function fixture(page: Page, options: {
  vm?: Record<string, unknown>;
  allowed?: boolean;
  failure?: number;
} = {}) {
  await page.clock.setFixedTime(new Date("2026-10-16T12:00:00Z"));
  await page.context().addCookies([{
    name: "strato-e2e", value: "terminal",
    url: `http://127.0.0.1:${process.env.E2E_APP_PORT ?? 3100}`,
  }]);
  const mutations: string[] = [];
  let failure = options.failure;
  await page.route("**/api/**", async route => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname;
    let data: unknown = url.searchParams.has("limit")
      ? { items: [], total: 0, limit: 500, offset: 0 }
      : [];
    if (path === "/api/authorization/check") {
      const checks = request.postDataJSON().checks as { key: string }[];
      data = { results: Object.fromEntries(checks.map(c => [c.key, options.allowed !== false])) };
    } else if (request.method() !== "GET") {
      mutations.push(`${request.method()} ${path}`);
      await route.fulfill({ status: 403, json: { reason: "Fixture rejects mutations" } });
      return;
    } else if (path === "/api/vms/vm-1") {
      if (failure) {
        await route.fulfill({ status: failure, json: { reason: "Fixture temporarily unavailable" } });
        return;
      }
      data = {
        id: "vm-1", name: "production-api-01",
        description: "Production API server · Europe West", status: "Running",
        projectId: "project-1", imageId: "image-1", image: "Ubuntu 24.04 LTS",
        hypervisorId: "eu-west-hv-03", hypervisorType: "qemu",
        cpu: 4, maxCpu: 8, memory: 8589934592, memoryFormatted: "8 GiB",
        guestMemoryUsedBytes: 3221225472, guestMemoryUsedFormatted: "3 GiB",
        diskFormatted: "40 GiB", secureBoot: true, tpmEnabled: true,
        metadataEnabled: true, graphicsConsole: true, guestAgentEnabled: true,
        guestAgentObservation: { checkedAt: "2026-10-16T12:00:00Z", reachable: true },
        resourceClassKind: "guaranteed", resourceClass: { revision: 3 },
        createdAt: "2026-10-01T09:30:00Z", updatedAt: "2026-10-16T11:42:00Z",
        conditions: {}, tags: { environment: "production", service: "api" },
        sshAuthorizedKeys: [],
        networkInterfaces: [{
          id: "nic-1", deviceName: "net0", network: "production", networkId: "network-1",
          macAddress: "52:54:00:a1:b2:c3",
          addresses: [{ address: "10.20.0.12", prefixLength: 24, gateway: "10.20.0.1" }],
          observedAddresses: [{ address: "10.20.0.12", prefixLength: 24 }],
          mtu: 1500, attachmentState: "attached",
        }],
        ...options.vm,
      };
    } else if (path === "/api/volumes") {
      data = { items: [{
        id: "volume-1", vmId: "vm-1", name: "api-data", deviceName: "vdb",
        size: 107374182400, sizeFormatted: "100 GiB", status: "attached",
      }], total: 1, limit: 500, offset: 0 };
    } else if (path === "/api/vms/vm-1/snapshots") {
      data = { items: [{
        id: "snapshot-1", name: "before-deploy", status: "ready",
        size: 12884901888, createdAt: "2026-10-16T08:15:00Z", qemuVersion: "11.0",
      }], total: 1, limit: 500, offset: 0 };
    } else if (path === "/api/organizations") {
      data = [{ id: "e2e-org", name: "Strato" }];
    }
    await route.fulfill({ json: data });
  });
  return { mutations, recover: () => { failure = undefined; } };
}

const before = process.env.VM_SCREENSHOT_LABEL === "before";

for (const [name, width, height] of [["desktop", 1600, 1100], ["mobile", 390, 844]] as const) {
  test(`VM detail ${name} review`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width, height });
    await fixture(page);
    await page.goto("/vms/vm-1");
    await expect(page.getByRole("heading", { name: "production-api-01" })).toBeVisible();
    await expect(page.getByText("api-data", { exact: true })).toBeVisible();
    await expect(page.getByText("before-deploy", { exact: true })).toBeVisible();
    await page.evaluate(() => document.fonts.ready);
    if (!before) {
      const main = await page.locator("main").boundingBox();
      const summary = await page.getByRole("region", { name: "Compute and connectivity" }).boundingBox();
      expect(summary!.width).toBeGreaterThan(main!.width - (width > 1000 ? 60 : 40));
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(width);
      await expect(page.getByRole("tab", { name: "Logs", exact: true })).toBeInViewport();
      if (name === "desktop") {
        await expect(page.getByText("api-data", { exact: true })).toBeInViewport();
      }
    }
    const label = process.env.VM_SCREENSHOT_LABEL ?? "after";
    const path = testInfo.outputPath(`${label}-${name}.png`);
    await page.screenshot({ path, fullPage: true });
    await testInfo.attach(`VM detail ${label} ${name}`, { path, contentType: "image/png" });
  });
}

test.describe("VM workspace behavior", () => {
  test.skip(before, "Baseline capture only");

  test("secondary controls expand by keyboard and console shortcut opens the existing terminal", async ({ page }) => {
    const { mutations } = await fixture(page);
    await page.routeWebSocket(/\/api\/vms\/vm-1\/console$/, ws => ws.send("ready"));
    await page.goto("/vms/vm-1");
    const guest = page.locator("summary").filter({ hasText: "Guest agent" });
    await guest.focus();
    await expect(guest).toBeFocused();
    await expect(page.getByText("Strato guest agent", { exact: true })).toBeHidden();
    await guest.press("Enter");
    await expect(page.getByText("Strato guest agent", { exact: true })).toBeVisible();
    await expect(page.getByText("Reachable", { exact: true })).toBeVisible();
    await guest.press("Space");
    await expect(page.getByText("Strato guest agent", { exact: true })).toBeHidden();
    await page.locator("summary").filter({ hasText: "Instance metadata" }).click();
    await page.getByRole("button", { name: "Edit metadata" }).click();
    await expect(page.getByRole("dialog")).toBeVisible();
    await page.keyboard.press("Escape");
    await page.getByRole("button", { name: "Open console" }).click();
    await expect(page.getByRole("tab", { name: "Console", exact: true })).toHaveAttribute("aria-selected", "true");
    await expect(page.getByText("Connected", { exact: true })).toBeVisible();
    expect(mutations).toEqual([]);
  });

  test("retains stopped/headless states and unknown agent state without exposing denied actions", async ({ page }) => {
    const { mutations } = await fixture(page, {
      allowed: false,
      vm: { status: "Shutdown", graphicsConsole: false, guestAgentEnabled: undefined, guestMemoryUsedBytes: null, guestMemoryUsedFormatted: null },
    });
    await page.goto("/vms/vm-1");
    await expect(page.getByRole("button", { name: "Open console" })).toBeDisabled();
    await expect(page.getByRole("tab", { name: /Console/ })).toBeDisabled();
    await expect(page.getByRole("tab", { name: /Display.*no display/ })).toBeDisabled();
    await expect(page.getByRole("tab", { name: "Exec", exact: true })).toHaveCount(0);
    await expect(page.getByRole("progressbar")).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Start production-api-01" })).toHaveCount(0);
    await expect(page.getByText("Opt-in state unavailable", { exact: true })).toBeVisible();
    await page.getByRole("button", { name: "More actions for production-api-01" }).click();
    await expect(page.getByRole("menuitem", { name: "Delete", exact: true })).toHaveCount(0);
    expect(mutations).toEqual([]);
  });

  test("preserves deletion confirmation and cancel without issuing a mutation", async ({ page }) => {
    const { mutations } = await fixture(page);
    await page.goto("/vms/vm-1");
    await page.getByRole("button", { name: "More actions for production-api-01" }).click();
    await page.getByRole("menuitem", { name: "Delete", exact: true }).click();
    await expect(page.getByRole("dialog", { name: "Delete production-api-01?" })).toBeVisible();
    await page.getByRole("button", { name: "Cancel", exact: true }).click();
    await expect(page.getByRole("dialog")).toHaveCount(0);
    expect(mutations).toEqual([]);
  });

  test("keeps retryable errors recoverable", async ({ page }) => {
    const { recover } = await fixture(page, { failure: 503 });
    await page.goto("/vms/vm-1");
    await expect(page.getByRole("alert").filter({ hasText: "Unable to load vm" })).toBeVisible();
    recover();
    await page.getByRole("button", { name: "Try again" }).click();
    await expect(page.getByRole("heading", { name: "production-api-01" })).toBeVisible();
  });

  test("long identifiers fit a narrow screen and optional memory targets remain visible", async ({ page }) => {
    await page.setViewportSize({ width: 320, height: 844 });
    await fixture(page, { vm: {
      name: "production-".repeat(12), hypervisorId: "hypervisor-".repeat(12),
      description: "description-".repeat(25), balloonTargetFormatted: "4 GiB",
      balloonTarget: 4294967296, guestMemoryBalloonActualBytes: 6442450944,
    } });
    await page.goto("/vms/vm-1");
    await expect(page.getByText("Limited to 4 GiB (reclaiming…)")).toBeVisible();
    await expect(page.getByRole("progressbar", { name: "Guest memory usage" })).toHaveAttribute("aria-valuenow", "38");
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(320);
  });
});
