import { test, expect, Page } from "@playwright/test";

const TABS = [
  "overview",
  "tasks",
  "product",
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
    // Rail click handlers attach late in app.js's async init chain; wait for
    // the real init-complete signal (see app.js data-app-ready) instead of
    // racing it. aria-current="page" on Overview is hardcoded in index.html,
    // so it is not a safe readiness indicator.
    // 15s: first navigation of a run pays server cold-start + full module
    // bootstrapping; the default 5s expect timeout is too tight for it.
    await expect(page.locator("body")).toHaveAttribute("data-app-ready", "1", {
      timeout: 15_000,
    });
    await expect(
      page.locator('.shell-rail-item[data-tab="overview"]'),
    ).toHaveAttribute("aria-current", "page");
  });

  for (const id of TABS) {
    test(`switches to "${id}" tab and shows matching pane`, async ({
      page,
    }) => {
      await page.locator(`.shell-rail-item[data-tab="${id}"]`).click();

      await expect(
        page.locator(`.shell-rail-item[data-tab="${id}"]`),
      ).toHaveAttribute("aria-current", "page");
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
    await page.locator('.shell-rail-item[data-tab="settings"]').click();
    await expect(page.locator("#tab-settings")).toHaveClass(/active/);
    await expect(page.locator("#tab-overview")).not.toHaveClass(/active/);
  });
});
