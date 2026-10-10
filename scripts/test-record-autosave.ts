import { chromium, expect as baseExpect, type Page } from "@playwright/test";
import { disposableOrigin, workspacePage } from "./test-origin";
// Record pages save themselves: choices on change, typed fields after a pause or on
// blur, leaving mid-typing still lands, a refused value blocks only its own field,
// another writer's edit never clobbers the field being typed in, and each autosave
// is one Undo step. Records open from the list in the same frame.
// Generous waits: these machines run many suites at once. Timing claims are asserted explicitly.
const expect = baseExpect.configure({ timeout: 15000 });
const url =
    process.env.IRIS_TEST_URL ??
    "http://iris-markdown.localhost:5198/workspace?review",
  origin = disposableOrigin(url);
const shots = process.env.IRIS_SHOTS;
const browser = await chromium.connectOverCDP(
  process.env.IRIS_CDP ?? "http://127.0.0.1:9222",
);
const editor = (page: Page) =>
  page.getByRole("complementary", { name: "Record editor", exact: true });
const writes = (page: Page) =>
  page.evaluate(() => (window as any).writeRequests as any[]);
async function otherClient(
  page: Page,
  id: string,
  patch: Record<string, unknown>,
) {
  await page.evaluate(
    async ({ id, patch }) => {
      const { WorkspaceDatabase } = await import("/src/lib/database.ts");
      const other = new WorkspaceDatabase();
      try {
        await other.request("open", { demo: true });
        const [row] = await other.request("rows", {
          view: {
            table: "notes",
            filters: [{ column: "id", op: "eq", value: id }],
            limit: 1,
          },
        });
        await other.request("write", {
          table: "notes",
          patch: { id: row.id, ...patch },
          expectedUpdatedAt: row.updated_at,
        });
      } finally {
        other.close();
      }
    },
    { id, patch },
  );
}
async function stored(page: Page, title: string) {
  return page.evaluate(async (title) => {
    const { WorkspaceDatabase } = await import("/src/lib/database.ts");
    const other = new WorkspaceDatabase();
    try {
      await other.request("open", { demo: true });
      const [row] = await other.request("rows", {
        view: {
          table: "notes",
          filters: [{ column: "title", op: "eq", value: title }],
          limit: 1,
        },
      });
      return row ?? null;
    } finally {
      other.close();
    }
  }, title);
}
/** Open from the list, then wait for the fresh row to unlock editing (inert until then). */
async function openListed(page: Page, name: string) {
  await page.getByRole("button", { name, exact: true }).click();
  await page.waitForFunction(
    () => document.querySelector(".record-panel form")?.inert === false,
  );
}
/** The list row is what the user sees stored: the grid refreshes after each write. */
function listed(page: Page, title: string, status: string) {
  return page
    .getByRole("grid", { name: "Records", exact: true })
    .getByRole("row", {
      name: new RegExp(`Title: ${title} Status: ${status}`),
    });
}
async function openSample(page: Page) {
  await page.goto(url);
  await page
    .getByRole("button", { name: "Try sample workspace", exact: true })
    .click();
  await expect(
    page.getByRole("grid", { name: "Records", exact: true }),
  ).toBeVisible({
    timeout: 30000,
  });
  // Find is disabled while the workspace is still opening.
  await expect(
    page.getByRole("button", { name: /Find records/ }),
  ).toBeEnabled();
}
try {
  const page = workspacePage(
    browser.contexts().flatMap((c) => c.pages()),
    url,
  );
  if (!page) throw Error("Owned test page unavailable");
  page.on("dialog", (d) => d.accept());
  page.setDefaultTimeout(15000);
  page.setDefaultNavigationTimeout(30000);
  await page.goto(new URL("/", url).href);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Storage.clearDataForOrigin", { origin, storageTypes: "all" });
  await cdp.detach();
  await page.addInitScript(() => {
    const state = window as any;
    state.holdWrites = false;
    state.heldWrites = [];
    state.writeRequests = [];
    state.writeReplies = [];
    state.holdReads = false;
    state.heldReads = [];
    state.releaseReads = () => {
      state.holdReads = false;
      state.heldReads.splice(0).forEach((deliver: () => void) => deliver());
    };
    state.releaseWrites = () => {
      state.holdWrites = false;
      state.heldWrites.splice(0).forEach((deliver: () => void) => deliver());
    };
    const Original = window.Worker;
    window.Worker = class extends Original {
      writes = new Set<number>();
      reads = new Set<number>();
      postMessage(message: any, ...args: any[]) {
        if (message.method === "rows") this.reads.add(message.id);
        if (message.method === "write") {
          this.writes.add(message.id);
          state.writeRequests.push({ ...message.args, at: performance.now() });
        }
        return super.postMessage(message, ...(args as [any]));
      }
      set onmessage(handler: any) {
        super.onmessage = (event) => {
          const write = this.writes.delete(event.data.id);
          if (write)
            state.writeReplies.push(
              event.data.error
                ? {
                    error: event.data.error.message,
                    violations: event.data.error.violations,
                  }
                : { ok: event.data.result?.updated_at },
            );
          const read = this.reads.delete(event.data.id);
          const deliver = () => handler.call(this, event);
          if (write && state.holdWrites) state.heldWrites.push(deliver);
          else if (read && state.holdReads) state.heldReads.push(deliver);
          else deliver();
        };
      }
    };
  });
  await openSample(page);

  // Instant open: the panel paints with the row's values in the frame after the click
  // (measured warm: the dev server compiles each component on its first render).
  await page
    .getByRole("button", { name: "A place to start", exact: true })
    .click();
  await page.getByRole("button", { name: "Close record", exact: true }).click();
  // Best of three warm opens: a loaded machine can stall any single frame.
  const paints: number[] = [];
  for (let run = 0; run < 3; run++) {
    if (run)
      await page
        .getByRole("button", { name: "Close record", exact: true })
        .click();
    paints.push(
      await page.evaluate(
        () =>
          new Promise<number>((resolve) => {
            const button = [...document.querySelectorAll("button")].find(
              (b) => b.textContent?.trim() === "A place to start",
            )!;
            const start = performance.now();
            button.click();
            const check = () => {
              const title =
                document.querySelector<HTMLInputElement>("#field-title");
              if (title?.value === "A place to start")
                resolve(performance.now() - start);
              else if (performance.now() - start > 3000) resolve(Infinity);
              else requestAnimationFrame(check);
            };
            requestAnimationFrame(check);
          }),
      ),
    );
  }
  const paint = Math.min(...paints);
  console.log(`first paint after click: ${paint.toFixed(1)} ms`);
  expect(paint).toBeLessThan(50);
  // First paint never waits for the database: with every row read held, the
  // record still paints from the list, locked until its fresh row arrives.
  await page.getByRole("button", { name: "Close record", exact: true }).click();
  await page.evaluate(() => ((window as any).holdReads = true));
  await page
    .getByRole("button", { name: "A place to start", exact: true })
    .click();
  await expect(page.locator("#field-title")).toHaveValue("A place to start", {
    timeout: 1000,
  });
  expect(
    await page.evaluate(
      () => document.querySelector(".record-panel form")?.inert,
    ),
  ).toBe(true);
  await page.evaluate(() => (window as any).releaseReads());
  await expect(editor(page).getByRole("button", { name: /^Save/ })).toHaveCount(
    0,
  );
  await expect(
    editor(page).getByRole("button", { name: "Cancel", exact: true }),
  ).toHaveCount(0);
  await expect(editor(page).getByText("Opening", { exact: false })).toHaveCount(
    0,
  );
  const title = page.getByRole("textbox", { name: "Title", exact: true });
  // Editing unlocks once the fresh full row is in (inert until then).
  await page.waitForFunction(
    () => document.querySelector(".record-panel form")?.inert === false,
  );
  await expect(title).toBeEditable();
  if (shots) await page.screenshot({ path: `${shots}/web-1-opened.png` });

  // A choice commits on change, with no idle wait.
  const before = (await writes(page)).length;
  const changed = await page.evaluate(() => performance.now());
  await page
    .getByRole("combobox", { name: "Status", exact: true })
    .selectOption("Ready");
  await expect.poll(async () => (await writes(page)).length).toBe(before + 1);
  const choice = (await writes(page)).at(-1);
  expect(choice.patch).toEqual({ id: choice.patch.id, status: "Ready" });
  expect(choice.at - changed).toBeLessThan(250);
  await expect(
    page.locator('[aria-label="Record save status"]'),
  ).toHaveAttribute("data-state", "saved");
  await expect(page.locator('[aria-label="Record save status"]')).toHaveText(
    /Saved/,
  );

  // Typing commits after a pause; the write carries only the changed field.
  await title.fill("A place to begin");
  await page.waitForTimeout(250);
  expect((await writes(page)).length).toBe(before + 1);
  await expect.poll(async () => (await writes(page)).length).toBe(before + 2);
  expect((await writes(page)).at(-1).patch).toEqual({
    id: choice.patch.id,
    title: "A place to begin",
  });
  // Each autosave is one Undo step.
  await page.getByRole("button", { name: /Undo last saved change/ }).click();
  await expect(title).toHaveValue("A place to start");
  await expect(
    page.getByRole("combobox", { name: "Status", exact: true }),
  ).toHaveValue("Ready");

  // Typing across an autosave and its refresh keeps focus and every keystroke.
  await title.focus();
  await title.fill("Kept");
  await expect
    .poll(async () => (await writes(page)).at(-1).patch.title)
    .toBe("Kept");
  await page.waitForTimeout(400);
  await page.keyboard.type(" focus");
  expect(await page.evaluate(() => document.activeElement?.id)).toBe(
    "field-title",
  );
  await expect(title).toHaveValue("Kept focus");

  // Blur commits at once.
  const typed = (await writes(page)).length;
  await title.fill("Blurred title");
  await title.press("Tab");
  await expect
    .poll(async () => (await writes(page)).length, { timeout: 300 })
    .toBe(typed + 1);

  // A refused value keeps its field editable with an inline error; the rest still saves.
  await title.fill("");
  // Move focus off the refused field, so only its refusal keeps the draft.
  await page.getByRole("combobox", { name: "Status", exact: true }).focus();
  await page
    .getByRole("combobox", { name: "Status", exact: true })
    .selectOption("Draft");
  await expect(editor(page).locator(".field-error")).toContainText(/required/i);
  await expect(title).toHaveAttribute("aria-invalid", "true");
  await expect(title).toBeEditable();
  await expect(listed(page, "Blurred title", "Draft")).toBeVisible();
  // The rest saved; the refused value is still the draft, still flagged.
  await page.waitForTimeout(300);
  await expect(title).toHaveValue("");
  await expect(editor(page).locator(".field-error")).toContainText(/required/i);
  if (shots)
    await page.screenshot({ path: `${shots}/web-2-refused-field.png` });
  await title.fill("Fixed title");
  await expect(listed(page, "Fixed title", "Draft")).toBeVisible();
  await expect(editor(page).locator(".field-error")).toHaveCount(0);

  // Another writer changes the record while a field is being typed in: untouched
  // fields update, the typed field is kept and still saves (no conflict).
  await title.focus();
  await title.fill("Typed while remote");
  await otherClient(page, choice.patch.id, { status: "Ready" });
  await expect(
    page.getByRole("combobox", { name: "Status", exact: true }),
  ).toHaveValue("Ready");
  await expect(title).toHaveValue("Typed while remote");
  await expect(listed(page, "Typed while remote", "Ready")).toBeVisible();
  await expect(editor(page).locator(".failure")).toHaveCount(0);

  // Leaving mid-typing still saves.
  await page.getByRole("button", { name: "Close record", exact: true }).click();
  await openListed(page, "Typed while remote");
  await title.fill("Left mid-typing");
  await page.getByRole("button", { name: "Close record", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Left mid-typing", exact: true }),
  ).toBeVisible();

  // The Markdown body keeps its editor autosave, and everything survives a reload.
  await openListed(page, "Left mid-typing");
  await page.getByRole("button", { name: "Body options", exact: true }).click();
  await page
    .getByRole("menuitem", { name: "Body source", exact: true })
    .click();
  await page
    .getByRole("textbox", { name: "Body", exact: true })
    .fill("Saved by the body editor");
  await expect(
    page.locator('[aria-label="Record save status"]'),
  ).toHaveAttribute("data-state", "saved");
  await openSample(page);
  await openListed(page, "Left mid-typing");
  await expect(title).toHaveValue("Left mid-typing");
  expect((await stored(page, "Left mid-typing"))?.body).toBe(
    "Saved by the body editor",
  );

  // A new record is created by its first valid edit; required fields gate it.
  await page.getByRole("button", { name: "Close record", exact: true }).click();
  await page
    .getByRole("button", { name: /New record/ })
    .first()
    .click();
  await page
    .getByRole("textbox", { name: "Title", exact: true })
    .fill("Created by typing");
  await expect(listed(page, "Created by typing", "Draft")).toBeVisible();
  await expect(editor(page).locator(".eyebrow")).toHaveText("Edit record");
  if (shots) await page.screenshot({ path: `${shots}/web-3-created.png` });
  console.log(
    "PASS: record autosave, refusals, remote merges, leave-saves, new records, instant open",
  );
} catch (error) {
  const page = workspacePage(
    browser.contexts().flatMap((c) => c.pages()),
    url,
  );
  if (page && shots)
    await page.screenshot({ path: `${shots}/web-failure.png` });
  if (page)
    console.error(
      JSON.stringify(
        await page.evaluate(() => ({
          requests: (window as any).writeRequests?.map((w: any) => w.patch),
          replies: (window as any).writeReplies,
        })),
      ),
    );
  throw error;
} finally {
  await browser.close();
}
