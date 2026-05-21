import { test, expect, request } from "@playwright/test";
import * as fs from "fs";

interface Scenario {
  type: string;
  title: string;
  questionId: string;
  instanceId: string;
  respondUrl: string;
  submit: Record<string, string>;
  responsesUrl: string;
  injectUrl: string;
  apiKey: string;
}

function loadScenarios(): Scenario[] {
  const manifestPath = process.env.DOTBOT_MOTHERSHIP_SCENARIOS;
  if (!manifestPath || !fs.existsSync(manifestPath)) {
    throw new Error(
      "DOTBOT_MOTHERSHIP_SCENARIOS is not set or file not found. " +
        "Run via tests/Test-E2E-Mothership-QA.ps1.",
    );
  }
  return JSON.parse(fs.readFileSync(manifestPath, "utf-8"));
}

const scenarios = loadScenarios();

for (const scenario of scenarios) {
  test.describe(`Mothership respond flow — ${scenario.type}`, () => {
    test("renders question title and correct UI elements", async ({ page }) => {
      await page.goto(scenario.respondUrl);

      // Title visible
      await expect(
        page.locator("p.question-text", { hasText: scenario.title }),
      ).toBeVisible();

      if (scenario.type === "singleChoice") {
        const options = page.locator(
          'input[type="radio"], button[data-key], label[data-key]',
        );
        await expect(options.first()).toBeVisible();
      }

      if (scenario.type === "approval") {
        await expect(
          page.locator('[value="approve"], [data-key="approve"]').first(),
        ).toBeVisible();
        await expect(
          page.locator('[value="reject"], [data-key="reject"]').first(),
        ).toBeVisible();
      }

      if (scenario.type === "documentReview") {
        await expect(
          page.locator('[value="approve"], [data-key="approve"]').first(),
        ).toBeVisible();
      }
    });

    test("submits response and redirects to confirmation", async ({ page }) => {
      await page.goto(scenario.respondUrl);

      if (scenario.type === "singleChoice") {
        const radio = page
          .locator(`input[type="radio"][value="${scenario.submit.selectedKey}"]`)
          .first();
        if (await radio.isVisible()) {
          await radio.check();
        } else {
          await page
            .locator(`[data-key="${scenario.submit.selectedKey}"], button:has-text("Option A")`)
            .first()
            .click();
        }
      }

      if (scenario.type === "approval" || scenario.type === "documentReview") {
        const decision = scenario.submit.approvalDecision ?? "approve";
        const radio = page
          .locator(`input[type="radio"][value="${decision}"]`)
          .first();
        if (await radio.isVisible()) {
          await radio.check();
        } else {
          await page
            .locator(`[data-key="${decision}"], button:has-text("Approve")`)
            .first()
            .click();
        }
      }

      const submitBtn = page
        .locator('button[type="submit"], input[type="submit"]')
        .first();
      await expect(submitBtn).toBeVisible();
      await submitBtn.click();

      await expect(page).toHaveURL(/confirmation|respond/i, { timeout: 10_000 });
      await expect(
        page.getByText(/response recorded|thank you|submitted/i).first(),
      ).toBeVisible({ timeout: 10_000 });
    });

    test("response payload persisted in storage", async () => {
      const apiContext = await request.newContext({
        baseURL: process.env.DOTBOT_E2E_URL,
        extraHTTPHeaders: { "X-Api-Key": scenario.apiKey },
      });

      // Inject a response directly via test endpoint
      const injectBody: Record<string, unknown> = {
        projectId:     scenario.respondUrl.match(/projectId=([^&]+)/)?.[1] ?? "playwright-e2e",
        questionId:    scenario.questionId,
        instanceId:    scenario.instanceId,
        responderEmail: "playwright-test@test.local",
        selectedKey:   scenario.submit.selectedKey ?? scenario.submit.approvalDecision ?? "approve",
        freeText:      null,
      };

      const inject = await apiContext.post(scenario.injectUrl, { data: injectBody });
      expect(inject.ok()).toBeTruthy();

      // Verify it surfaces at the responses endpoint
      const listResp = await apiContext.get(scenario.responsesUrl);
      expect(listResp.ok()).toBeTruthy();

      const responses = await listResp.json();
      expect(Array.isArray(responses)).toBeTruthy();
      expect(responses.length).toBeGreaterThan(0);

      const last = responses[responses.length - 1];
      if (scenario.submit.selectedKey) {
        expect(last.selectedKey).toBe(scenario.submit.selectedKey);
      }

      await apiContext.dispose();
    });
  });
}
