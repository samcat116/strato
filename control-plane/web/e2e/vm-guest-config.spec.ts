import { expect, test, type Page } from "@playwright/test";

async function fixture(page: Page, allowed = true) {
  await page.context().addCookies([{ name: "strato-e2e", value: "terminal", url: `http://127.0.0.1:${process.env.E2E_APP_PORT ?? 3100}` }]);
  let reads = 0;
  let writes = 0;
  const keys: string[] = [];
  const config = { packages: [], files: [{ path: "/etc/app.conf", mode: "0600", content: "STR92_SECRET_SENTINEL" }], services: [], sysctls: [] };
  const vm = { id: "vm-1", name: "Config test VM", status: "Running", guestAgentEnabled: true, cpu: 2, maxCpu: 2, memoryFormatted: "2 GiB", diskFormatted: "10 GiB", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", conditions: { generation: 5, observedGeneration: 0, converged: false }, networkInterfaces: [] };
  await page.route("**/api/**", async route => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    let data: unknown = [];
    if (path === "/api/authorization/check") {
      const checks = request.postDataJSON().checks as { key: string; action: string }[];
      data = { results: Object.fromEntries(checks.map(c => [c.key, c.action === "vm:configureGuest" && allowed])) };
    } else if (path === "/api/vms/vm-1/guest-config") {
      if (request.method() === "PUT") {
        writes++;
        keys.push(request.headers()["idempotency-key"]);
        if (writes === 1) { await route.abort("connectionreset"); return; }
        await route.fulfill({ status: 202, json: { resource: vm, mutationId: "config-mutation", targetGeneration: 5 } });
        return;
      }
      reads++;
      data = { vmId: vm.id, desiredGeneration: 4, guestConfig: config, status: "pending", items: [] };
    } else if (path === "/api/vms/vm-1") {
      data = vm;
    } else if (path === "/api/organizations") {
      data = [{ id: "e2e-org", name: "Config tests" }];
    }
    await route.fulfill({ json: data });
  });
  return { reads: () => reads, writes: () => writes, keys };
}

test("a viewer does not fetch privileged guest file content", async ({ page }) => {
  const state = await fixture(page, false);
  await page.goto("/vms/vm-1");
  await expect(page.getByText("Guest configuration", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Edit configuration" })).toHaveCount(0);
  expect(state.reads()).toBe(0);
});

test("invalid editor input stays inline and never sends a mutation", async ({ page }) => {
  const state = await fixture(page);
  await page.goto("/vms/vm-1");
  await page.getByRole("button", { name: "Edit configuration" }).click();
  await page.getByLabel("Configuration JSON").fill("invalid JSON");
  await page.getByRole("button", { name: "Save desired configuration" }).click();
  await expect(page.getByRole("alert").filter({ hasText: "Enter valid JSON" })).toBeVisible();
  expect(state.writes()).toBe(0);
});

test("a lost acceptance retries with the same key and never claims observed convergence", async ({ page }) => {
  const state = await fixture(page);
  await page.goto("/vms/vm-1");
  await expect(page.getByText("STR92_SECRET_SENTINEL", { exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Edit configuration" }).click();
  await page.getByLabel("Configuration JSON").fill("null");
  await page.getByRole("button", { name: "Save desired configuration" }).click();
  await expect(page.getByRole("dialog").getByRole("alert")).toBeVisible();
  await expect(page.getByLabel("Configuration JSON")).toHaveValue("null");
  await page.getByRole("button", { name: "Save desired configuration" }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(state.writes()).toBe(2);
  expect(state.keys[0]).toBeTruthy();
  expect(state.keys[1]).toBe(state.keys[0]);
  await expect(page.getByText(/Awaiting current guest read-back/)).toBeVisible();
});
