import { expect, test } from "@playwright/test";

test("preserves a protected deep link when redirecting to login", async ({ page }) => {
  await page.goto("/vms/vm-1?tab=logs#tail");

  await expect(page).toHaveURL(
    /\/login\?next=%2Fvms%2Fvm-1%3Ftab%3Dlogs%23tail$/
  );
  await expect(page.getByRole("heading", { name: "Sign in to Strato" })).toBeVisible();
});

test("explains an identity-provider callback failure", async ({ page }) => {
  await page.goto("/login?error=oidc_failed");

  await expect(
    page.getByRole("alert").filter({ hasText: "Single sign-on failed" })
  ).toBeVisible();
});
