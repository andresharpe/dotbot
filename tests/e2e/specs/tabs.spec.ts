import { test, expect, Page } from "@playwright/test";

const TABS = [
  "overview",
  "product",
  "pipeline",
  "processes",
  "decisions",
  "workflow",
  "settings",
] as const;

test.describe("Tab navigation", () => {
  test.beforeEach(async ({ page }) => {
    // Track only uncaught JS exceptions. console.error is too noisy: the
    // app legitimately logs poll failures there, and the browser emits
    // "Failed to load resource: net::*" for transient network blips.
    const pageErrors: string[] = [];
    page.on("pageerror", (err) => pageErrors.push(err.message));
    (page as Page & { __pageErrors: string[] }).__pageErrors = pageErrors;

    await page.goto("/");
    await expect(page.locator('.tab[data-tab="overview"]')).toHaveClass(
      /active/,
    );
  });

  for (const id of TABS) {
    test(`switches to "${id}" tab and shows matching pane`, async ({
      page,
    }) => {
      await page.locator(`.tab[data-tab="${id}"]`).click();

      await expect(page.locator(`.tab[data-tab="${id}"]`)).toHaveClass(
        /active/,
      );
      await expect(page.locator(`#tab-${id}`)).toHaveClass(/active/);

      const errors = (page as Page & { __pageErrors: string[] }).__pageErrors;
      expect(
        errors,
        `Uncaught page errors after switching to "${id}":\n${errors.join("\n")}`,
      ).toEqual([]);
    });
  }

  test("activating one tab deactivates the previously active pane", async ({
    page,
  }) => {
    await page.locator('.tab[data-tab="settings"]').click();
    await expect(page.locator("#tab-settings")).toHaveClass(/active/);
    await expect(page.locator("#tab-overview")).not.toHaveClass(/active/);
  });
});
