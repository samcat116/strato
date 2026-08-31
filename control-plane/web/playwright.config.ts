import { defineConfig, devices } from "@playwright/test";

const mockPort = 18_080;
const appPort = 3_100;
const mockOrigin = `http://127.0.0.1:${mockPort}`;

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL: `http://127.0.0.1:${appPort}`,
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
  webServer: [
    {
      command: "bun run test:e2e:backend",
      port: mockPort,
      reuseExistingServer: !process.env.CI,
    },
    {
      command: `bun run dev --hostname 127.0.0.1 --port ${appPort}`,
      env: {
        NEXT_PUBLIC_API_URL: mockOrigin,
        STRATO_API_URL: mockOrigin,
      },
      port: appPort,
      reuseExistingServer: !process.env.CI,
      timeout: 120_000,
    },
  ],
});
