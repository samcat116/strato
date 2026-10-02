import { expect, test } from "@playwright/test";

for (const allowed of [true, false]) {
  test(`live sessions with termination permission ${allowed}`, async ({ page }) => {
    await page.context().addCookies([{ name: "strato-e2e", value: "terminal", url: `http://127.0.0.1:${process.env.E2E_APP_PORT ?? 3100}` }]);
    let pending = false;
    let ended = false;
    let terminations = 0;
    await page.route("**/api/**", async route => {
      const request = route.request();
      const path = new URL(request.url()).pathname;
      let data: unknown = [];
      if (path === "/api/authorization/check") {
        const checks = request.postDataJSON().checks as { key: string; action: string }[];
        data = { results: Object.fromEntries(checks.map(c => [c.key, c.action === "vm:exec" && allowed])) };
      } else if (path === "/api/vms/vm-1/exec-sessions/session-1/terminate") {
        expect(allowed).toBe(true);
        expect(request.method()).toBe("POST");
        terminations++;
        pending = true;
        await route.fulfill({ status: 202 });
        return;
      } else if (path === "/api/vms/vm-1/exec-sessions") {
        data = ended ? [] : [{ sessionId: "session-1", userId: "user-1", username: "alice", attachedAt: "2026-10-02T00:00:00Z", lastActivityAt: "2026-10-02T00:00:00Z", terminationRequested: pending }];
      } else if (path === "/api/vms/vm-1") {
        data = { id: "vm-1", name: "Session test VM", status: "Running", guestAgentEnabled: true, cpu: 2, maxCpu: 2, memoryFormatted: "2 GiB", diskFormatted: "10 GiB", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", conditions: {}, networkInterfaces: [] };
      } else if (path === "/api/organizations") {
        data = [{ id: "e2e-org", name: "Session tests" }];
      }
      await route.fulfill({ json: data });
    });
    await page.goto("/vms/vm-1");
    await expect(page.getByText("alice", { exact: true })).toBeVisible();
    const terminate = page.getByRole("button", { name: "Terminate", exact: true });
    if (allowed) {
      await terminate.click();
      await expect(page.getByText("Termination pending", { exact: true })).toBeVisible();
      await expect(terminate).toBeDisabled();
      expect(terminations).toBe(1);
      ended = true;
      await expect(page.getByText("No attached sessions.", { exact: true })).toBeVisible({ timeout: 10000 });
    } else {
      await expect(terminate).toHaveCount(0);
      expect(terminations).toBe(0);
    }
  });
}
