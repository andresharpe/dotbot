import { test, expect, request } from "@playwright/test";
import * as fs from "fs";

interface RankedItem {
  optionId: string;
  rank: number;
}

interface Scenario {
  type: string;
  /**
   * Optional disambiguator used when more than one scenario shares a `type`
   * (currently: approval `no-attachments` vs `with-attachments`). Drives the
   * test-describe label so Playwright does not collapse them.
   */
  variant?: string | null;
  title: string;
  questionId: string;
  instanceId: string;
  respondUrl: string;
  submit: {
    selectedKey?: string;
    approvalDecision?: string;
    freeText?: string;
    rankedItems?: RankedItem[];
    /**
     * For approval-with-attachments: the server-issued attachment IDs the
     * fixture confirmed. Both used to tick the per-attachment checklist on
     * the form and injected into the test response so the persisted record
     * round-trips the same set.
     */
    reviewedAttachmentIds?: string[];
  };
  responsesUrl: string;
  injectUrl: string;
  apiKey: string;
}

function loadScenarios(): Scenario[] {
  const manifestPath = process.env.DOTBOT_MOTHERSHIP_SCENARIOS;
  if (!manifestPath || !fs.existsSync(manifestPath)) {
    return [];
  }
  return JSON.parse(fs.readFileSync(manifestPath, "utf-8"));
}

const scenarios = loadScenarios();

if (scenarios.length === 0) {
  test.skip(
    "Mothership scenarios not available — set DOTBOT_MOTHERSHIP_SCENARIOS or run via Test-E2E-Mothership-QA.ps1",
    () => {},
  );
}

for (const scenario of scenarios) {
  const label = scenario.variant ? `${scenario.type}-${scenario.variant}` : scenario.type;
  const hasAttachmentChecklist =
    scenario.type === "approval" &&
    Array.isArray(scenario.submit.reviewedAttachmentIds) &&
    scenario.submit.reviewedAttachmentIds.length > 0;

  test.describe(`Mothership respond flow — ${label}`, () => {
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
          page.locator('[value="approved"], [data-key="approve"]').first(),
        ).toBeVisible();
        await expect(
          page.locator('[value="rejected"], [data-key="reject"]').first(),
        ).toBeVisible();

        if (hasAttachmentChecklist) {
          // The approval-with-attachments form renders one
          // <input type="checkbox" name="reviewedAttachmentIds" value="<id>" />
          // per template attachment, above the decision buttons (Respond.cshtml
          // line 78). Verify each expected id is present.
          for (const id of scenario.submit.reviewedAttachmentIds!) {
            await expect(
              page.locator(
                `input[type="checkbox"][name="reviewedAttachmentIds"][value="${id}"]`,
              ),
            ).toBeVisible();
          }
        }
      }

      if (scenario.type === "freeText") {
        await expect(page.locator('textarea[name="freeText"]')).toBeVisible();
      }

      if (scenario.type === "priorityRanking") {
        await expect(page.locator(".rank-item").first()).toBeVisible();
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

      if (scenario.type === "approval") {
        // For approval-with-attachments the form's submit guard blocks the
        // decision until at least one reviewedAttachmentIds checkbox is
        // ticked (Respond.cshtml line 194-205). Tick every expected id.
        if (hasAttachmentChecklist) {
          for (const id of scenario.submit.reviewedAttachmentIds!) {
            await page
              .locator(
                `input[type="checkbox"][name="reviewedAttachmentIds"][value="${id}"]`,
              )
              .check();
          }
        }

        const decision = scenario.submit.approvalDecision ?? "approved";
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
        baseURL: process.env.DOTBOT_SERVER_URL ?? "http://localhost:5048",
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
      } else if (scenario.type === "approval") {
        injectBody.approvalDecision = scenario.submit.approvalDecision ?? "approved";
        if (hasAttachmentChecklist) {
          injectBody.reviewedAttachmentIds = scenario.submit.reviewedAttachmentIds;
        }
      } else {
        injectBody.selectedKey = scenario.submit.selectedKey;
      }

      const inject = await apiContext.post(scenario.injectUrl, { data: injectBody });
      expect(inject.ok()).toBeTruthy();

      const listResp = await apiContext.get(scenario.responsesUrl);
      expect(listResp.ok()).toBeTruthy();

      const responses = await listResp.json();
      expect(Array.isArray(responses)).toBeTruthy();
      expect(responses.length).toBeGreaterThan(0);

      // SPEC-029: GET responses returns assembled envelopes - the payload is under
      // .answer (and the question type under .question.type).
      const last = responses[responses.length - 1];
      const answer = last.answer ?? {};
      if (scenario.type === "freeText") {
        expect(answer.freeText).toBe(scenario.submit.freeText);
      } else if (scenario.type === "priorityRanking") {
        expect(Array.isArray(answer.rankedItems)).toBeTruthy();
        expect(answer.rankedItems.length).toBeGreaterThan(0);
      } else if (scenario.type === "approval") {
        expect(answer.approvalDecision).toBe(scenario.submit.approvalDecision ?? "approved");
        if (hasAttachmentChecklist) {
          const persisted: string[] = Array.isArray(answer.reviewedAttachmentIds)
            ? answer.reviewedAttachmentIds.map((g: string) => String(g))
            : [];
          const expected = scenario.submit.reviewedAttachmentIds!.map((g) => String(g));
          // Order-independent equality: server may normalise or sort.
          expect(persisted.sort()).toEqual(expected.sort());
        }
      } else if (scenario.submit.selectedKey) {
        expect(answer.selectedKey).toBe(scenario.submit.selectedKey);
      }

      await apiContext.dispose();
    });
  });
}
