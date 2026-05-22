import { test, expect, request } from "@playwright/test";
import * as fs from "fs";

interface RankedItem {
  optionId: string;
  rank: number;
}

interface Scenario {
  type: string;
  title: string;
  questionId: string;
  instanceId: string;
  respondUrl: string;
  submit: {
    selectedKey?: string;
    approvalDecision?: string;
    freeText?: string;
    rankedItems?: RankedItem[];
  };
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

      await expect(
        page.locator("p.question-text", { hasText: scenario.title }),
      ).toBeVisible();

      if (scenario.type === "singleChoice" || scenario.type === "multiChoice") {
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

      if (scenario.type === "freeText") {
        await expect(page.locator('textarea[name="freeText"]')).toBeVisible();
      }

      if (scenario.type === "priorityRanking") {
        await expect(page.locator('.rank-item').first()).toBeVisible();
      }
    });

    test("submits response and redirects to confirmation", async ({ page }) => {
      await page.goto(scenario.respondUrl);

      if (scenario.type === "singleChoice" || scenario.type === "multiChoice") {
        const key = scenario.submit.selectedKey!;
        const radio = page
          .locator(`input[type="radio"][value="${key}"]`)
          .first();
        if (await radio.isVisible()) {
          await radio.check();
        } else {
          await page
            .locator(`[data-key="${key}"], button:has-text("Option A")`)
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

      if (scenario.type === "freeText") {
        await page.locator('textarea[name="freeText"]').fill(scenario.submit.freeText!);
      }

      // priorityRanking: JS pre-populates rankedItemsJson on submit — no interaction needed

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

      const projectId =
        scenario.respondUrl.match(/projectId=([^&]+)/)?.[1] ?? "playwright-e2e";

      const injectBody: Record<string, unknown> = {
        projectId,
        questionId:     scenario.questionId,
        instanceId:     scenario.instanceId,
        responderEmail: "playwright-test@test.local",
      };

      if (scenario.type === "freeText") {
        injectBody.freeText = scenario.submit.freeText ?? "test answer";
      } else if (scenario.type === "priorityRanking") {
        injectBody.rankedItems = scenario.submit.rankedItems;
      } else {
        injectBody.selectedKey =
          scenario.submit.selectedKey ?? scenario.submit.approvalDecision ?? "approve";
        injectBody.freeText = null;
      }

      const inject = await apiContext.post(scenario.injectUrl, { data: injectBody });
      expect(inject.ok()).toBeTruthy();

      const listResp = await apiContext.get(scenario.responsesUrl);
      expect(listResp.ok()).toBeTruthy();

      const responses = await listResp.json();
      expect(Array.isArray(responses)).toBeTruthy();
      expect(responses.length).toBeGreaterThan(0);

      const last = responses[responses.length - 1];
      if (scenario.type === "freeText") {
        expect(last.freeText).toBe(scenario.submit.freeText);
      } else if (scenario.type === "priorityRanking") {
        expect(Array.isArray(last.rankedItems)).toBeTruthy();
        expect(last.rankedItems.length).toBeGreaterThan(0);
      } else if (scenario.submit.selectedKey) {
        expect(last.selectedKey).toBe(scenario.submit.selectedKey);
      }

      await apiContext.dispose();
    });
  });
}
