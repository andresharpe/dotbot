import { test, expect } from "@playwright/test";
import {
  seedTask,
  removeTask,
  type SeededTask,
  seedProcess,
  removeProcess,
  type SeededProcess,
} from "../helpers/fixture";

test.describe("Task list rendering (Roadmap tab)", () => {
  const seeded: SeededTask[] = [];

  test.afterEach(async () => {
    while (seeded.length > 0) {
      const t = seeded.pop()!;
      try {
        removeTask(t);
      } catch {}
    }
  });

  test("renders one row per todo task with the seeded name", async ({
    page,
  }) => {
    const a = seedTask("todo", { name: "list-spec-alpha" });
    const b = seedTask("todo", { name: "list-spec-bravo" });
    const c = seedTask("todo", { name: "list-spec-charlie" });
    seeded.push(a, b, c);

    await page.goto("/");
    // Wait for the seeded tasks to land in state before opening the tab,
    // otherwise the assertion can race the "Loading…" placeholder.
    await expect(page.locator("#todo-count")).toHaveText("3", {
      timeout: 10_000,
    });

    await page.locator('.tab[data-tab="pipeline"]').click();
    await expect(page.locator("#tab-pipeline")).toHaveClass(/active/);

    const rows = page.locator("#upcoming-tasks .task-list-item");
    await expect(rows).toHaveCount(3, { timeout: 10_000 });

    const names = page.locator("#upcoming-tasks .task-list-item-name");
    await expect(names).toContainText([
      "list-spec-alpha",
      "list-spec-bravo",
      "list-spec-charlie",
    ]);
  });

  test("renders empty state when no tasks exist", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator("#todo-count")).toHaveText("0", {
      timeout: 10_000,
    });
    await page.locator('.tab[data-tab="pipeline"]').click();
    await expect(page.locator("#upcoming-tasks .task-list-item")).toHaveCount(
      0,
    );
  });
});

test.describe("Process list rendering (Processes tab)", () => {
  const seededProcs: SeededProcess[] = [];

  test.afterEach(async () => {
    while (seededProcs.length > 0) {
      const p = seededProcs.pop()!;
      try {
        removeProcess(p);
      } catch {}
    }
  });

  test("renders a row for a seeded running process", async ({ page }) => {
    const proc = seedProcess({
      type: "execution",
      status: "running",
      description: "list-spec running execution",
    });
    seededProcs.push(proc);

    await page.goto("/");
    await page.locator('.tab[data-tab="processes"]').click();
    await expect(page.locator("#tab-processes")).toHaveClass(/active/);

    const row = page.locator(
      `#process-list .process-row[data-process-id="${proc.id}"]`,
    );
    await expect(row).toBeVisible({ timeout: 10_000 });
    await expect(row).toContainText("list-spec running execution");
  });

  test("renders empty state when no process JSONs exist", async ({ page }) => {
    await page.goto("/");
    await page.locator('.tab[data-tab="processes"]').click();
    await expect(page.locator("#tab-processes")).toHaveClass(/active/);

    await expect(page.locator("#process-list .empty-state")).toBeVisible({
      timeout: 10_000,
    });
  });
});
