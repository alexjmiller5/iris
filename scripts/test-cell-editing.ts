// Single-click cell editing against the synthetic sample workspace.
// Uses a disposable Chrome profile. Start the dev server at IRIS_TEST_URL first.
import { chromium, expect } from "@playwright/test";
const browser = await chromium.launch({ channel: "chrome", headless: true });
const url = process.env.IRIS_TEST_URL ?? "http://127.0.0.1:5267/workspace";
const page = await browser.newPage();

page.setDefaultTimeout(15000);
page.on("pageerror", (e) => console.error(e));
page.on("console", (m) => {
  if (m.type() === "error") console.error(m.text());
});
try {
  await page.goto(url, { timeout: 180000 });
  const sample = page.getByRole("button", { name: "Try sample workspace" });
  await expect(sample).toBeVisible({ timeout: 180000 });
  await sample.click();
  const status = page
    .locator('[role="gridcell"][data-column="status"]')
    .first();
  await status.click();
  await expect(
    page.getByRole("button", { name: "Ready", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Save cell", exact: true }),
  ).toHaveCount(0);
  await page.getByRole("button", { name: "Ready", exact: true }).click();
  await expect(status).toContainText("Ready");
  await expect(page.locator("[data-cell-editor]")).toHaveCount(0);
  const title = page.locator('[role="gridcell"][data-column="title"]').first();
  await title.click();
  const input = page.getByRole("textbox", { name: "Title", exact: true });
  await expect(input).toBeFocused();
  await input.fill("A single click title");
  // Attachment downloads click a body-mounted anchor programmatically.
  const downloadAllowed = await page.evaluate(() => {
    const anchor = document.createElement("a");
    anchor.href = "data:text/plain,synthetic";
    anchor.download = "synthetic.txt";
    document.body.append(anchor);
    let allowed = false;
    anchor.onclick = (event) => {
      allowed = !event.defaultPrevented;
      event.preventDefault();
    };
    anchor.click();
    anchor.remove();
    return allowed;
  });
  expect(downloadAllowed).toBe(true);
  await expect(input).toBeVisible();
  // The first outside click only saves and dismisses, even over another cell.
  await status.click();
  await expect(title).toContainText("A single click title");
  await expect(page.locator("[data-cell-editor]")).toHaveCount(0);
  await expect(status).toContainText("Ready");
  await status.click();
  await expect(
    page.getByRole("button", { name: "Draft", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Draft", exact: true }).click();
  await expect(page.locator("[data-cell-editor]")).toHaveCount(0);
  await title.click();
  await page
    .getByRole("textbox", { name: "Title", exact: true })
    .fill("Click away saves");
  await page.getByRole("heading").first().click();
  await expect(title).toContainText("Click away saves");
  await expect(page.locator("[data-cell-editor]")).toHaveCount(0);
  await status.click();
  await title.click({ button: "middle" });
  await expect(page.locator("[data-cell-editor]")).toHaveCount(0);
  await status.click();
  const open = title.getByTitle("Open record");
  await open.click();
  await expect(page.locator("[data-cell-editor]")).toHaveCount(0);
  await expect(page.getByRole("textbox", { name: "Title", exact: true })).toHaveCount(0);
  await open.click();
  await expect(page.getByRole("textbox", { name: "Title", exact: true })).toBeVisible();
  console.log(
    "PASS: one click choices, immediate save, text focus, dismissal-only outside clicks, second-click record opening",
  );
} catch (error) {
  console.error(await page.locator("body").innerText());
  await page.screenshot({ path: "/tmp/iris-cell-web-failure.png" });
  throw error;
} finally {
  await browser.close();
}
