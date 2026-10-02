import { expect, test, type Page } from "@playwright/test";

async function fixture(page: Page, options: { allowed?: boolean; status?: string; enabled?: boolean; missingOptIn?: boolean } = {}) {
  await page.context().addCookies([{ name: "strato-e2e", value: "terminal", url: `http://127.0.0.1:${process.env.E2E_APP_PORT ?? 3100}` }]);
  let minted = 0;
  await page.route("**/api/**", async route => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    let data: unknown = [];
    if (path === "/api/authorization/check") {
      const checks = request.postDataJSON().checks as { key: string; action: string }[];
      data = { results: Object.fromEntries(checks.map(c => [c.key, c.action === "vm:exec" && options.allowed !== false])) };
    } else if (/\/api\/vms\/vm-\d\/exec$/.test(path)) {
      minted++;
      data = { sessionId: `session-${minted}`, websocketPath: `${path}/session-${minted}/attach`, expiresAt: new Date(Date.now() + 60000).toISOString() };
      expect(request.postDataJSON()).toMatchObject({ command: ["/bin/sh"], tty: true });
    } else if (/\/api\/vms\/vm-\d$/.test(path)) {
      data = { id: path.split("/").at(-1), name: "Exec test VM", status: options.status ?? "Running", guestAgentEnabled: options.missingOptIn ? undefined : options.enabled ?? true, cpu: 2, maxCpu: 2, memoryFormatted: "2 GiB", diskFormatted: "10 GiB", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", conditions: {}, networkInterfaces: [] };
    } else if (path === "/api/organizations") {
      data = [{ id: "e2e-org", name: "Terminal tests" }];
    }
    await route.fulfill({ json: data });
  });
  return () => minted;
}

test("real xterm survives disconnect/retry, tab closure, repeated opens and navigation", async ({ page }) => {
  const minted = await fixture(page);
  const sessions: { closed: boolean }[] = [];
  let attached = 0;
  await page.routeWebSocket(/\/exec\/.*\/attach$/, ws => {
    attached++;
    const session = { closed: false };
    sessions.push(session);
    ws.send(JSON.stringify({ type: "ready" }));
    ws.onMessage(message => {
      if (typeof message !== "string") {
        ws.send(Buffer.from("received stdin\r\n"));
        ws.close({ code: 1000, reason: "interrupted fixture" });
      }
    });
    ws.onClose(() => { session.closed = true; });
  });
  await page.goto("/vms/vm-1");
  await page.getByRole("tab", { name: "Exec", exact: true }).click();
  await expect(page.getByText("Connected", { exact: true })).toBeVisible();
  const initialMints = minted(); // Strict Mode can mint an abandoned pending session.
  expect(attached).toBe(1);
  await page.locator(".xterm-helper-textarea").press("x");
  await expect(page.getByText("Disconnected", { exact: true })).toBeVisible();
  expect(minted()).toBe(initialMints);
  await page.getByRole("button", { name: "Run", exact: true }).click();
  await expect(page.getByText("Connected", { exact: true })).toBeVisible();
  expect(minted()).toBe(initialMints + 1);
  expect(attached).toBe(2);
  for (let i = 0; i < 2; i++) {
    const currentSession = sessions.at(-1)!;
    await page.getByRole("tab", { name: "Overview", exact: true }).click();
    await expect.poll(() => currentSession.closed).toBe(true);
    await page.getByRole("tab", { name: "Exec", exact: true }).click();
    await expect(page.getByText("Connected", { exact: true })).toBeVisible();
    expect(attached).toBe(i + 3);
  }
  await expect(page.getByRole("tab", { name: "Console", exact: true })).toBeEnabled();
  const currentSession = sessions.at(-1)!;
  await page.goto("/vms/vm-2");
  await expect.poll(() => currentSession.closed).toBe(true);
  await page.getByRole("tab", { name: "Exec", exact: true }).click();
  await expect(page.getByText("Connected", { exact: true })).toBeVisible();
  expect(attached).toBe(5);
});

test("denied exec never exposes or mints a session", async ({ page }) => {
  const minted = await fixture(page, { allowed: false });
  await page.goto("/vms/vm-1");
  await expect(page.getByRole("heading", { name: "Exec test VM" })).toBeVisible();
  await expect(page.getByRole("tab", { name: "Exec", exact: true })).toHaveCount(0);
  expect(minted()).toBe(0);
});

for (const [message, remedy] of [
  ["VM vm-1 has no guest agent", "Install and start"],
  ["guest agent not responding for VM vm-1: timeout", "Check the Strato guest agent service"],
]) {
  test(`explains ${message} with serial console recovery`, async ({ page }) => {
    await fixture(page);
    await page.routeWebSocket(/\/exec\/.*\/attach$/, ws => ws.send(JSON.stringify({ type: "error", message })));
    await page.goto("/vms/vm-1");
    await page.getByRole("tab", { name: "Exec", exact: true }).click();
    await expect(page.getByRole("alert").filter({ hasText: message })).toContainText(remedy);
    await expect(page.getByRole("button", { name: "Run", exact: true })).toBeEnabled();
    await expect(page.getByRole("tab", { name: "Console", exact: true })).toBeEnabled();
  });
}

for (const options of [
  { status: "Stopped", enabled: true, message: "VM is not running" },
  { status: "Running", enabled: false, message: "Strato guest agent channel is disabled" },
  { status: "Running", missingOptIn: true, message: "Guest-agent opt-in state is unavailable" },
]) {
  test(`prevents startup when ${options.message}`, async ({ page }) => {
    const minted = await fixture(page, options);
    await page.goto("/vms/vm-1");
    await page.getByRole("tab", { name: "Exec", exact: true }).click();
    await expect(page.getByRole("status").filter({ hasText: options.message })).toBeVisible();
    expect(minted()).toBe(0);
  });
}
