import { test, expect } from "@playwright/test";
import {
  seedProcess,
  removeProcess,
  type SeededProcess,
} from "../helpers/fixture";

test.describe("Control buttons emit correct backend requests", () => {
  test('panic RESET button POSTs /api/control with {action:"reset"}', async ({
    page,
  }) => {
    await page.goto("/");
    await expect(page.locator('.tab[data-tab="overview"]')).toHaveClass(
      /active/,
    );

    // app.js's DOMContentLoaded handler awaits initSidebar() before calling
    // initControlButtons(), so the panic-reset listener isn't attached at
    // load. Without this wait the click silently no-ops.
    await page.waitForLoadState("networkidle");

    const reset = page.locator("#panic-reset");
    await expect(reset).toBeVisible();

    const [request] = await Promise.all([
      page.waitForRequest(
        (req) => req.url().endsWith("/api/control") && req.method() === "POST",
        { timeout: 5_000 },
      ),
      reset.click(),
    ]);

    const body = JSON.parse(request.postData() ?? "{}");
    expect(body.action).toBe("reset");
  });

  test("workflow Stop button POSTs /api/workflows/{name}/stop when a runner is active", async ({
    page,
  }) => {
    // server.ps1 flips has_running_process=true for a workflow when any
    // task-runner's description contains the workflow name.
    const proc: SeededProcess = seedProcess({
      type: "task-runner",
      status: "running",
      description: "Running start-from-prompt workflow",
    });

    try {
      await page.goto("/");

      const stopBtn = page.locator(
        '#workflow-controls-container .process-control-row[data-workflow="start-from-prompt"] .wf-stop-btn',
      );
      await expect(stopBtn).toBeVisible({ timeout: 10_000 });
      await expect(stopBtn).toBeEnabled({ timeout: 10_000 });

      const [request] = await Promise.all([
        page.waitForRequest(
          (req) =>
            /\/api\/workflows\/start-from-prompt\/stop$/.test(req.url()) &&
            req.method() === "POST",
          { timeout: 5_000 },
        ),
        stopBtn.click(),
      ]);

      expect(request.method()).toBe("POST");
    } finally {
      removeProcess(proc);
    }
  });
});
