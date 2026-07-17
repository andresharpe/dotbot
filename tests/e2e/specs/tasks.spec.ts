import { test, expect } from "@playwright/test";
import { seedTask, removeTask, type SeededTask } from "../helpers/fixture";

// Unified Tasks surface (#606): filter chips + task list + detail panel.
test.describe("Tasks surface", () => {
  const seeded: SeededTask[] = [];

  test.afterEach(async () => {
    while (seeded.length > 0) {
      const t = seeded.pop()!;
      try {
        removeTask(t);
      } catch {}
    }
  });

  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await expect(page.locator("body")).toHaveAttribute("data-app-ready", "1", {
      timeout: 15_000,
    });
  });

  test("chip filtering changes the visible row set", async ({ page }) => {
    seeded.push(seedTask("todo", { name: "tasks-spec-todo" }));

    await expect(page.locator("#todo-count")).toHaveText("1", {
      timeout: 10_000,
    });

    await page.locator('.shell-rail-item[data-tab="tasks"]').click();
    await expect(page.locator("#tab-tasks")).toHaveClass(/active/);

    // All filter shows the row
    await page.locator('.filter-chip[data-task-filter="all"]').click();
    await expect(page.locator("#tasks-list .task-list-item")).toHaveCount(1);

    // Done filter hides it
    await page.locator('.filter-chip[data-task-filter="done"]').click();
    await expect(
      page.locator('.filter-chip[data-task-filter="done"]'),
    ).toHaveClass(/active/);
    await expect(page.locator("#tasks-list .task-list-item")).toHaveCount(0);

    // Todo filter shows it again
    await page.locator('.filter-chip[data-task-filter="todo"]').click();
    await expect(page.locator("#tasks-list .task-list-item")).toHaveCount(1);
  });

  test("row click opens the detail panel; Full detail opens the modal", async ({
    page,
  }) => {
    seeded.push(seedTask("todo", { name: "tasks-spec-panel" }));

    await expect(page.locator("#todo-count")).toHaveText("1", {
      timeout: 10_000,
    });
    await page.locator('.shell-rail-item[data-tab="tasks"]').click();

    const row = page.locator("#tasks-list .task-list-item").first();
    await expect(row).toBeVisible({ timeout: 10_000 });
    // Click the name, not the action buttons
    await row.locator(".task-list-item-name").click();

    const panel = page.locator("#task-detail-panel");
    await expect(panel).toContainText("tasks-spec-panel");
    await expect(panel.locator(".task-detail-full-link")).toBeVisible();

    // Full detail opens the deep-view modal
    await panel.locator(".task-detail-full-link").click();
    await expect(page.locator("#task-modal")).toHaveClass(/visible/);
  });

  test("clicking a task action button does not open the detail panel", async ({
    page,
  }) => {
    seeded.push(seedTask("todo", { name: "tasks-spec-guard" }));

    await expect(page.locator("#todo-count")).toHaveText("1", {
      timeout: 10_000,
    });
    await page.locator('.shell-rail-item[data-tab="tasks"]').click();

    const row = page.locator("#tasks-list .task-list-item").first();
    await expect(row).toBeVisible({ timeout: 10_000 });

    // The edit action opens the edit modal — the panel must stay empty
    await row.locator('[data-task-action="edit-task"]').click();
    await expect(page.locator("#task-edit-modal")).toHaveClass(/visible/, {
      timeout: 10_000,
    });
    await expect(page.locator("#task-detail-panel .empty-state")).toBeVisible();
  });
});
