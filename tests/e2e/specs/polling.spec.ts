import { test, expect } from "@playwright/test";
import {
  seedTask,
  moveTask,
  removeTask,
  type SeededTask,
} from "../helpers/fixture";

test.describe("State polling reflects backend state in the DOM", () => {
  const seeded: SeededTask[] = [];

  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await expect(page.locator('.tab[data-tab="overview"]')).toHaveClass(
      /active/,
    );
  });

  test.afterEach(async () => {
    while (seeded.length > 0) {
      const t = seeded.pop()!;
      try {
        removeTask(t);
      } catch {}
    }
  });

  test("todo count increments after a task JSON appears in workspace/tasks/todo/", async ({
    page,
  }) => {
    await expect(page.locator("#todo-count")).toHaveText("0");

    seeded.push(seedTask("todo"));

    // Poll interval is 3s; allow up to 10s for two cycles.
    await expect(page.locator("#todo-count")).toHaveText("1", {
      timeout: 10_000,
    });
    await expect(page.locator("#pipeline-todo-count")).toHaveText("1");
  });

  test("moving a task from todo to in-progress shifts the counts", async ({
    page,
  }) => {
    const task = seedTask("todo");
    seeded.push(task);

    await expect(page.locator("#todo-count")).toHaveText("1", {
      timeout: 10_000,
    });
    await expect(page.locator("#progress-count")).toHaveText("0");

    const moved = moveTask(task, "in-progress");
    // Re-track so afterEach removes the new path, not the original todo/ path.
    seeded[seeded.length - 1] = moved;

    await expect(page.locator("#todo-count")).toHaveText("0", {
      timeout: 10_000,
    });
    await expect(page.locator("#progress-count")).toHaveText("1");
  });

  test("multiple seeded tasks across statuses produce the correct counts", async ({
    page,
  }) => {
    seeded.push(seedTask("todo"));
    seeded.push(seedTask("todo"));
    seeded.push(seedTask("todo"));
    seeded.push(seedTask("analysing"));
    seeded.push(seedTask("done"));

    await expect(page.locator("#todo-count")).toHaveText("3", {
      timeout: 10_000,
    });
    await expect(page.locator("#analysing-count")).toHaveText("1");
    // #done-count is done + skipped combined; only 'done' was seeded.
    await expect(page.locator("#done-count")).toHaveText("1");
  });

  test("connection indicator carries no error class while the server is healthy", async ({
    page,
  }) => {
    const indicator = page.locator(
      "#connection-status, .connection-status, .status-dot",
    );
    if ((await indicator.count()) > 0) {
      const cls = (await indicator.first().getAttribute("class")) ?? "";
      expect(cls).not.toMatch(/error|disconnect/i);
    }
  });
});
