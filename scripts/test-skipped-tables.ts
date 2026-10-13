import { chromium, expect, type Page } from "@playwright/test";
import { logDDL, regressionHub } from "./workspace-regression-hub";
import {
  disposableOrigin,
  recordReady,
  recordSaved,
  workspacePage,
} from "./test-origin";

// A table this device skips is read-only and asks to download it when opened: Not now keeps
// it read-only and asks again on the next visit, "Don't show this again" stops asking until
// Settings shows the prompt again, and approving downloads the table and makes it editable.
// Edits queued before the skip wait for the table in the pill, then upload.
const source = process.argv[2];
if (!source)
  throw Error("Usage: bun scripts/test-skipped-tables.ts <soma-checkout>");
const url =
  process.env.IRIS_TEST_URL ??
  "http://iris-downloads.localhost:5371/workspace?review";
const origin = disposableOrigin(url);
const shots = process.env.IRIS_TEST_SHOTS;
let refusePush = false;
const { server, db } = await regressionHub(source, origin, 0, {
  wrap: (worker) => ({
    async fetch(request: Request, env: unknown, context: unknown) {
      if (
        refusePush &&
        request.method === "POST" &&
        new URL(request.url).pathname === "/v1/rows/push"
      ) {
        const body = (await request.clone().json()) as { table?: string };
        if (body.table === "archive")
          return new Response("Fixture push failure", {
            status: 503,
            headers: { "Access-Control-Allow-Origin": origin },
          });
      }
      return worker.fetch(request, env, context);
    },
  }),
});
const system = `id TEXT PRIMARY KEY NOT NULL DEFAULT (lower(hex(randomblob(16)))),created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),deleted_at TEXT,hub_at TEXT`;
logDDL(db, `CREATE TABLE "archive" (${system},title TEXT,note TEXT)`);
db.db
  .exec(`INSERT INTO catalog_tables(id,kind,display,purpose) VALUES ('archive','table','title','Synthetic archive');
	INSERT INTO catalog_properties(id,tbl,col,label,sort,type,required) VALUES
	('archive.title','archive','title','Title',0,'text',1),('archive.note','archive','note','Note',1,'text',0);`);
for (let i = 1; i <= 5; i++)
  db.db
    .query("INSERT INTO archive(id,title,note) VALUES (?,?,?)")
    .run(`archive-${i}`, `Archived ${i}`, "Synthetic archived note text");

async function shot(page: Page, name: string) {
  if (!shots) return;
  await page.emulateMedia({ colorScheme: "light" });
  await page.screenshot({ path: `${shots}/${name}.png` });
  await page.emulateMedia({ colorScheme: "dark" });
  await page.screenshot({ path: `${shots}/${name}-dark.png` });
  await page.emulateMedia({ colorScheme: null });
}

const browser = await chromium.connectOverCDP(
  process.env.IRIS_TEST_CDP ?? "http://127.0.0.1:9222",
);
let owned: Page | undefined;
try {
  const pages = browser.contexts().flatMap((c) => c.pages());
  const page = (owned =
    workspacePage(pages, url) ?? (await browser.contexts()[0].newPage()));
  page.setDefaultTimeout(15000);
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(new URL("/", url).href);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  await cdp.detach();
  await page.goto(url);
  await page
    .getByRole("button", { name: "Open my workspace", exact: true })
    .click();
  await page.getByText("Connect to a hub", { exact: true }).click();
  await page.getByText("Use a device token", { exact: true }).click();
  await page.getByLabel("Hub address").fill(server.url.href.replace(/\/$/, ""));
  await page.getByLabel("Device token").fill("fixture");
  const connect = page.getByRole("button", { name: "Connect", exact: true });
  await connect.click();
  await expect(connect).toBeEnabled({ timeout: 30000 });

  const tables = page.getByRole("navigation", { name: "Tables" });
  const open = async (name: string) => {
    await tables.getByRole("button", { name, exact: true }).click();
    await expect(
      page.getByRole("heading", { name, exact: true }),
    ).toBeVisible();
  };
  const prompt = page.getByRole("dialog", {
    name: "Not synced on this device",
    exact: true,
  });
  const pill = page.getByLabel(/^Sync status:/);
  const notice = page.getByTestId("skipped-notice");
  const newRecord = page.getByRole("button", {
    name: "New record",
    exact: true,
  });
  const limit = page.getByLabel("Automatic sync row limit", { exact: true });
  const hubTitle = () =>
    (
      db.db.query("SELECT title FROM archive WHERE id='archive-1'").get() as {
        title: string;
      }
    ).title;

  // An edit made while archive syncs, held back by a failing push, then the row limit drops
  // below archive's five rows: the edit waits for archive instead of reading as Syncing.
  await open("archive");
  await expect(newRecord).toBeEnabled();
  refusePush = true;
  await page.getByRole("button", { name: "Archived 1", exact: true }).click();
  await recordReady(page);
  await page
    .getByRole("textbox", { name: "Title", exact: true })
    .fill("Edited before the skip");
  await recordSaved(page);
  await page.getByRole("button", { name: "Close record", exact: true }).click();
  await expect(page.locator('[data-pending="1"]')).toBeVisible();
  await limit.fill("4");
  await limit.dispatchEvent("change");
  await expect(pill).toHaveAccessibleName(
    "Sync status: 1 waiting for archive to sync",
    {
      timeout: 20000,
    },
  );
  await expect(pill).toHaveAttribute(
    "title",
    "These edits upload once this device downloads archive. Open it to change its download setting.",
  );
  expect(hubTitle()).toBe("Archived 1");
  // Skipped while open: the notice explains, without interrupting with the prompt.
  await expect(notice).toContainText("Not synced on this device.");
  await expect(prompt).toHaveCount(0);
  await expect(newRecord).toBeDisabled();
  await shot(page, "01-waiting-pill");
  console.log(
    "PASS: an edit queued before the skip waits for its table; the open table turns read-only",
  );

  // Opening the skipped table asks, with its size and the suggested setting.
  await open("widgets");
  await open("archive");
  await expect(prompt).toBeVisible();
  await expect(prompt).toContainText("archive");
  await expect(prompt).toContainText("1 earlier edit uploads once it syncs.");
  await expect(prompt.locator(".size")).toHaveText(
    /^5 rows · about \d+ bytes$/,
  );
  await expect(
    prompt.getByRole("radio", { name: /Download this table on this device/ }),
  ).toBeChecked();
  await expect(
    prompt.getByRole("radio", { name: /Raise the automatic row limit/ }),
  ).not.toBeChecked();
  await shot(page, "02-prompt");
  await prompt.getByRole("button", { name: "Not now", exact: true }).click();
  await expect(prompt).toHaveCount(0);
  await expect(newRecord).toBeDisabled();
  await expect(
    notice.getByRole("button", { name: "Download…", exact: true }),
  ).toBeVisible();
  await shot(page, "03-read-only");
  await open("widgets");
  await open("archive");
  await expect(prompt).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(prompt).toHaveCount(0);
  await expect(newRecord).toBeDisabled();
  console.log(
    "PASS: Not now and Escape keep the table read-only, and the prompt returns on the next visit",
  );

  // Don't show this again stops it for this table only, until Settings shows it again.
  await open("widgets");
  await open("archive");
  await prompt
    .getByRole("checkbox", { name: "Don't show this again for this table" })
    .check();
  await prompt.getByRole("button", { name: "Not now", exact: true }).click();
  await open("widgets");
  await open("archive");
  await page.waitForTimeout(1000);
  await expect(prompt).toHaveCount(0);
  await expect(newRecord).toBeDisabled();
  const hidden = page.getByRole("list", {
    name: "Download prompts turned off",
  });
  await expect(hidden.getByRole("listitem")).toHaveCount(1);
  await expect(hidden).toContainText("archive");
  await hidden.scrollIntoViewIfNeeded();
  await shot(page, "04-settings");
  await hidden
    .getByRole("button", { name: "Show prompt for archive", exact: true })
    .click();
  await expect(hidden).toHaveCount(0);
  await open("widgets");
  await open("archive");
  await expect(prompt).toBeVisible();
  console.log(
    "PASS: the checkbox stops the prompt for this table and Settings brings it back",
  );

  // Approving a slightly modified suggestion: a higher row limit downloads the table.
  refusePush = false;
  await prompt
    .getByRole("radio", { name: /Raise the automatic row limit/ })
    .check();
  const rows = prompt.getByRole("spinbutton", {
    name: "Row limit",
    exact: true,
  });
  await expect(rows).toHaveValue("5");
  await rows.fill("3");
  await expect(
    prompt.getByRole("button", { name: "Download", exact: true }),
  ).toBeDisabled();
  await rows.fill("10");
  await prompt.getByRole("button", { name: "Download", exact: true }).click();
  await expect(prompt).toHaveCount(0);
  await expect(notice).toHaveCount(0, { timeout: 20000 });
  await expect(newRecord).toBeEnabled();
  await expect(limit).toHaveValue("10");
  await expect
    .poll(hubTitle, { timeout: 20000 })
    .toBe("Edited before the skip");
  await expect(pill).not.toHaveAccessibleName(/waiting/);
  await page
    .getByRole("button", { name: "Edited before the skip", exact: true })
    .click();
  await recordReady(page);
  await page
    .getByRole("textbox", { name: "Title", exact: true })
    .fill("Editable again");
  await recordSaved(page);
  await expect.poll(hubTitle, { timeout: 20000 }).toBe("Editable again");
  await page.getByRole("button", { name: "Close record", exact: true }).click();
  console.log(
    "PASS: approving a raised limit downloads the table, uploads the waiting edit and allows editing",
  );

  // The default suggestion: include just this table, whatever the limit.
  await limit.fill("4");
  await limit.dispatchEvent("change");
  await expect(notice).toBeVisible({ timeout: 20000 });
  await open("widgets");
  await open("archive");
  await expect(prompt).toBeVisible();
  await prompt.getByRole("button", { name: "Download", exact: true }).click();
  await expect(notice).toHaveCount(0, { timeout: 20000 });
  await expect(newRecord).toBeEnabled();
  await expect(limit).toHaveValue("4");
  await shot(page, "05-downloaded");
  console.log(
    "PASS: approving the suggested include downloads the table under a lower limit",
  );
} finally {
  await owned?.close().catch(() => {});
  await browser.close();
  server.stop(true);
  db.db.close();
}
