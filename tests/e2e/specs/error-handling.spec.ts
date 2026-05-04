import { test, expect } from "@playwright/test";

/**
 * Network-layer fault injection via page.route() — the only mocking in
 * the suite. The browser receives a genuine HTTP 500 over a real
 * connection; the server, .bot/, DOM and polling cycle are untouched.
 */

test.describe("UI degrades gracefully on server errors", () => {
  test("a 500 from /api/state does not throw a JS error or freeze the page", async ({
    page,
  }) => {
    const pageErrors: string[] = [];
    const consoleErrors: string[] = [];
    page.on("pageerror", (err) => pageErrors.push(err.message));
    page.on("console", (msg) => {
      if (msg.type() === "error") consoleErrors.push(msg.text());
    });

    await page.route("**/api/state", async (route) => {
      await route.fulfill({
        status: 500,
        contentType: "application/json",
        body: JSON.stringify({ error: "simulated transient backend error" }),
      });
    });

    await page.goto("/");

    // Two poll cycles at 3s each, plus margin.
    await page.waitForTimeout(7_000);

    expect(
      pageErrors,
      `Uncaught page errors:\n${pageErrors.join("\n")}`,
    ).toEqual([]);

    await page.locator('.tab[data-tab="settings"]').click();
    await expect(page.locator("#tab-settings")).toHaveClass(/active/);
    await page.locator('.tab[data-tab="overview"]').click();
    await expect(page.locator("#tab-overview")).toHaveClass(/active/);

    // Confirm the error path ran rather than passing silently.
    const sawPollError = consoleErrors.some((m) => /Poll error/i.test(m));
    expect(
      sawPollError,
      `expected at least one "Poll error:" console message; got:\n${consoleErrors.join("\n")}`,
    ).toBe(true);
  });

  test("after the error clears, the next poll re-renders state", async ({
    page,
  }) => {
    let failNext = true;
    await page.route("**/api/state", async (route) => {
      if (failNext) {
        failNext = false;
        await route.fulfill({
          status: 500,
          contentType: "application/json",
          body: '{"error":"transient"}',
        });
      } else {
        // Recovery is exercised against the real server, not a second mock.
        await route.continue();
      }
    });

    await page.goto("/");
    await expect(page.locator("#todo-count")).toHaveText("0", {
      timeout: 10_000,
    });
  });
});
