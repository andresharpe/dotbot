import { test, expect } from "@playwright/test";
import * as fs from "node:fs";
import * as path from "node:path";
import { BOT_DIR } from "../helpers/fixture";

test.describe("Settings persistence via real /api/settings", () => {
  // Specs share one fixture (workers=1); restore the settings file so
  // downstream specs aren't polluted by what we toggled here.
  const settingsBackup: Record<string, string> = {};
  const settingsCandidates = [
    path.join(BOT_DIR, ".control", "settings.json"),
    path.join(BOT_DIR, ".control", "ui-settings.json"),
    path.join(BOT_DIR, "settings", "settings.user.json"),
  ];

  test.beforeAll(() => {
    for (const f of settingsCandidates) {
      if (fs.existsSync(f)) settingsBackup[f] = fs.readFileSync(f, "utf8");
    }
  });

  test.afterAll(() => {
    for (const f of settingsCandidates) {
      if (settingsBackup[f] !== undefined) {
        fs.writeFileSync(f, settingsBackup[f], "utf8");
      } else if (fs.existsSync(f)) {
        fs.unlinkSync(f);
      }
    }
  });

  test('toggling "show debug" issues POST /api/settings and survives reload', async ({
    page,
  }) => {
    await page.goto("/");
    // initSettingsToggles() binds change handlers after several awaited
    // fetches inside the DOMContentLoaded handler.
    await page.waitForLoadState("networkidle");
    await page.locator('.tab[data-tab="settings"]').click();
    await expect(page.locator("#tab-settings")).toHaveClass(/active/);

    // show-debug lives in #settings-execution, which starts hidden until
    // its sub-nav item is selected.
    await page
      .locator('.settings-nav-item[data-settings-section="execution"]')
      .click();
    await expect(page.locator("#settings-execution")).not.toHaveClass(/hidden/);

    // The <input> is CSS-hidden; users click the wrapping <label>, which
    // is what dispatches click+change on the underlying checkbox.
    const toggle = page.locator("#setting-show-debug");
    await expect(toggle).toHaveCount(1);
    const toggleLabel = toggle.locator(
      'xpath=ancestor::label[contains(@class,"toggle-switch")][1]',
    );
    await expect(toggleLabel).toBeVisible();

    const initial = await toggle.isChecked();
    const target = !initial;

    const [request] = await Promise.all([
      page.waitForRequest(
        (req) => req.url().endsWith("/api/settings") && req.method() === "POST",
        { timeout: 5_000 },
      ),
      toggleLabel.click(),
    ]);

    const body = JSON.parse(request.postData() ?? "{}");
    expect(body.showDebug).toBe(target);

    // Reload exercises the GET round-trip: stored value → /api/settings → UI.
    await page.reload();
    await page.waitForLoadState("networkidle");
    await page.locator('.tab[data-tab="settings"]').click();
    await page
      .locator('.settings-nav-item[data-settings-section="execution"]')
      .click();
    const reloaded = page.locator("#setting-show-debug");
    await expect(reloaded).toHaveCount(1);
    await expect(reloaded).toBeChecked({ checked: target, timeout: 5_000 });
  });
});
