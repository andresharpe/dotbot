import { test, expect } from "@playwright/test";
import { seedActivityEvent } from "../helpers/fixture";

test.describe("Dispatch ticker feed mode (#607)", () => {
  // First test bears the cold-server load; persistence test reloads mid-test.
  test.setTimeout(45_000);

  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    // Ticker.init() runs inside the async DOMContentLoaded init chain;
    // data-app-ready flips once listeners (click toggle) are attached.
    await expect(page.locator("body")).toHaveAttribute("data-app-ready", "1", {
      timeout: 15_000,
    });
    // Mode persists in localStorage across specs (workers=1); reset both the
    // stored key and the live attribute in place — a reload here would double
    // the page-load cost of every test.
    await page.evaluate(() => {
      localStorage.removeItem("dotbot:shell:tickerMode");
      document.getElementById("shell-ticker")?.removeAttribute("data-mode");
    });
  });

  test("defaults to static line, click toggles feed and persists", async ({
    page,
  }) => {
    const ticker = page.locator("#shell-ticker");
    await expect(ticker).toBeVisible();
    // Default = no data-mode attribute → static summary line shown.
    await expect(ticker).not.toHaveAttribute("data-mode", "feed");
    await expect(page.locator("#shell-ticker .shell-ticker-line")).toBeVisible();

    await ticker.click();
    await expect(ticker).toHaveAttribute("data-mode", "feed");
    await expect(page.locator("#shell-ticker .shell-ticker-line")).toBeHidden();

    // Persisted: survives reload.
    await page.reload();
    await expect(page.locator("body")).toHaveAttribute("data-app-ready", "1", {
      timeout: 15_000,
    });
    await expect(page.locator("#shell-ticker")).toHaveAttribute(
      "data-mode",
      "feed",
    );

    // Toggle back to static and confirm.
    await page.locator("#shell-ticker").click();
    await expect(page.locator("#shell-ticker")).not.toHaveAttribute(
      "data-mode",
      "feed",
    );
    await expect(page.locator("#shell-ticker .shell-ticker-line")).toBeVisible();
  });

  test("seeded task status change appears as a dispatch line", async ({
    page,
  }) => {
    await page.locator("#shell-ticker").click();
    await expect(page.locator("#shell-ticker")).toHaveAttribute(
      "data-mode",
      "feed",
    );

    seedActivityEvent("task.status_changed", {
      task_id: "t_e2e12345",
      from: "analysing",
      to: "analysed",
      actor: "e2e",
    });

    // pollActivity runs every 2s; 10s covers poll + render comfortably.
    await expect(page.locator("#ticker-feed-track")).toContainText(
      "moved to analysed",
      { timeout: 10_000 },
    );
  });

  test("prefers-reduced-motion renders a single static entry", async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion: "reduce" });

    seedActivityEvent("task.status_changed", {
      task_id: "t_e2e54321",
      from: "todo",
      to: "in-progress",
      actor: "e2e",
    });

    await page.locator("#shell-ticker").click();
    await expect(page.locator("#shell-ticker")).toHaveAttribute(
      "data-mode",
      "feed",
    );

    const track = page.locator("#ticker-feed-track");
    await expect(track).toContainText("moved to in-progress", {
      timeout: 10_000,
    });

    // Reduced mode: exactly one entry (no duplicated halves), no animation.
    await expect(track.locator(".shell-ticker-entry")).toHaveCount(1);
    const animationName = await track.evaluate(
      (el) => getComputedStyle(el).animationName,
    );
    expect(animationName).toBe("none");
  });
});
