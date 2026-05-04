import { defineConfig } from "@playwright/test";

const baseURL = process.env.DOTBOT_E2E_URL;
if (!baseURL) {
  throw new Error(
    "DOTBOT_E2E_URL is not set. Layer 5 tests are launched via tests/Test-UI-E2E.ps1, " +
      "which boots the UI server against a golden .bot/ fixture and exports the URL.",
  );
}

export default defineConfig({
  testDir: "./specs",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: process.env.CI
    ? [["list"], ["html", { open: "never" }]]
    : [["list"]],
  timeout: 30_000,
  expect: { timeout: 5_000 },
  use: {
    baseURL,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    video: "retain-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { browserName: "chromium" },
    },
  ],
});
