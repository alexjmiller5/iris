import { createServer } from "node:http";
import { writeFile, readFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
const origin =
  process.env.CAPTURE_TEST_ORIGIN ?? "http://life-ui-capture.localhost:5267";
const targets = await (
  await fetch((process.env.CDP_URL ?? "http://127.0.0.1:9222") + "/json/list")
).json();
const target = targets.find(
  (t: any) => t.type === "page" && t.url.startsWith(origin),
);
if (!target) throw Error("Open the owned capture fixture tab first.");
const ws = new WebSocket(target.webSocketDebuggerUrl);
const pending = new Map<
  number,
  { resolve: (x: any) => void; reject: (x: any) => void }
>();
let sequence = 0;
ws.onmessage = (event) => {
  const body = JSON.parse(String(event.data));
  const waiter = pending.get(body.id);
  if (waiter) {
    pending.delete(body.id);
    if (body.error) waiter.reject(body.error);
    else waiter.resolve(body.result);
  }
};
await new Promise<void>((resolve, reject) => {
  ws.onopen = () => resolve();
  ws.onerror = reject;
});
function send(method: string, params: object = {}) {
  return new Promise<any>((resolve, reject) => {
    const id = ++sequence;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
}
async function evaluate(expression: string) {
  const answer = await send("Runtime.evaluate", {
    expression,
    awaitPromise: true,
    returnByValue: true,
    userGesture: true,
  });
  if (answer.exceptionDetails)
    throw Error(
      answer.exceptionDetails.exception?.description ??
        answer.exceptionDetails.text,
    );
  return answer.result.value;
}
let requests = 0;
const sink = createServer((_, response) => {
  requests++;
  response.writeHead(200, { "Content-Type": "text/plain" });
  response.end("synthetic sink");
});
await new Promise<void>((resolve) => sink.listen(0, "127.0.0.1", resolve));
const address = sink.address();
if (!address || typeof address === "string") throw Error("Sink unavailable");
const sinkURL = `http://127.0.0.1:${address.port}`;
const downloadDirectory = await mkdtemp(
  join(tmpdir(), "life-capture-download-"),
);
try {
  await send("Page.setDownloadBehavior", {
    behavior: "allow",
    downloadPath: downloadDirectory,
  });
  await send("Page.navigate", { url: origin });
  await evaluate(`new Promise(resolve=>setTimeout(resolve,800))`);
  async function mountFixture(sinkURL: string) {
    const { mount } = await import("/node_modules/.vite/deps/svelte.js");
    const { default: Viewer } =
      await import("/src/lib/PageCaptureViewer.svelte");
    const html = `<h1>Readable archive</h1><img src="${sinkURL}/image"><style>@import url('${sinkURL}/style');</style><a href="${sinkURL}/link">Blocked link</a><form action="${sinkURL}/form"><button>Submit</button></form><meta http-equiv="refresh" content="0;url=${sinkURL}/refresh"><script>parent.document.body.dataset.escaped='yes';fetch('${sinkURL}/script')</script><svg><a href="${sinkURL}/svg"><text x="0" y="20">SVG link</text><set attributeName="href" to="${sinkURL}/set" /></a></svg>`;
    const png = Uint8Array.from(
      atob(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lm0AAAAASUVORK5CYII=",
      ),
      (c) => c.charCodeAt(0),
    );
    const files = {
      html: new Blob([html], { type: "text/html" }),
      png: new Blob([png], { type: "image/png" }),
    };
    const row: any = {
      id: "fixture-attempt",
      capture_id: "fixture-capture",
      event_id: "fixture-event",
      subscription_id: "fixture-subscription",
      source_table: "articles",
      source_row_id: "fixture-row",
      source_column: "url",
      source_url: "https://example.test/original",
      observed_source_revision: "{}",
      attempted_at: "2026-01-01T00:00:00.000Z",
      captured_at: "2026-01-01T00:00:01.000Z",
      status: "partial",
      failure_code: "partial",
      failure_detail:
        "Incomplete archive: 2 resource requests could not be saved; 1 section was still loading.",
    };
    for (const kind of ["png", "html"] as const) {
      const blob = files[kind];
      row[`${kind}_key`] = `captures/page.${kind}`;
      row[`${kind}_mime`] = blob.type;
      row[`${kind}_bytes`] = blob.size;
      row[`${kind}_sha256`] = Array.from(
        new Uint8Array(
          await crypto.subtle.digest("SHA-256", await blob.arrayBuffer()),
        ),
      )
        .map((x) => x.toString(16).padStart(2, "0"))
        .join("");
    }
    const state = window as any;
    state.captureFiles = files;
    state.captureHold = false;
    state.captureRequests = 0;
    const resolveFile = async (key: string) => {
      state.captureRequests++;
      if (state.captureHold)
        await new Promise<void>((resolve) => (state.captureRelease = resolve));
      const blob = key.endsWith("html") ? files.html : files.png;
      const url = URL.createObjectURL(blob);
      return {
        url,
        contentType: blob.type,
        dispose: () => URL.revokeObjectURL(url),
      };
    };
    const target = document.createElement("div");
    document.body.append(target);
    state.captureMount = mount(Viewer, { target, props: { row, resolveFile } });
  }
  await evaluate(`(${mountFixture.toString()})(${JSON.stringify(sinkURL)})`);
  await evaluate(
    `(async()=>{const image=document.createElement('img');image.src=${JSON.stringify(sinkURL)}+'/control';document.body.append(image);await new Promise(r=>setTimeout(r,150));image.remove();})()`,
  );
  if (requests === 0)
    throw Error("Network positive control did not reach sink");
  requests = 0;
  const result = await evaluate(
    `(${async function acceptance() {
      const state = window as any;
      const wait = async (predicate: () => unknown) => {
        for (let i = 0; i < 150; i++) {
          if (predicate()) return;
          await new Promise((r) => setTimeout(r, 30));
        }
        throw Error("Timed out waiting for fixture");
      };
      const button = (name: string) =>
        Array.from(document.querySelectorAll("button")).find(
          (b) => b.textContent?.trim() === name,
        )!;
      button("View page capture").click();
      await wait(() => document.querySelector("dialog img"));
      button("Archived HTML").click();
      await wait(() => document.querySelector('iframe[title="Archived page"]'));
      const iframe = document.querySelector(
        'iframe[title="Archived page"]',
      ) as HTMLIFrameElement;
      if (iframe.getAttribute("sandbox") !== "")
        throw Error("Sandbox permits capabilities");
      if (!iframe.srcdoc.includes("Readable archive"))
        throw Error("Readable content missing");
      if (
        /href=|http-equiv="refresh"|<script|<set/.test(
          iframe.srcdoc.replace(/<meta[^>]*>/g, ""),
        )
      )
        throw Error("Active archive navigation surface remains");
      await new Promise((r) => setTimeout(r, 300));
      if (document.body.dataset.escaped) throw Error("Archive script executed");
      const openedHTML = iframe.srcdoc;
      button("Done").click();
      button("View page capture").click();
      await wait(() => document.querySelector("dialog img"));
      state.captureHold = true;
      button("Archived HTML").click();
      await wait(() => typeof state.captureRelease === "function");
      button("Done").click();
      state.captureHold = false;
      button("View page capture").click();
      await wait(() => document.querySelector("dialog img"));
      state.captureRelease();
      await new Promise((r) => setTimeout(r, 150));
      const failure = document.querySelector('dialog [role="alert"]');
      if (failure)
        throw Error(
          "Late canceled operation changed reopened viewer: " +
            failure.textContent,
        );
      button("Archived HTML").click();
      await wait(() => document.querySelector("dialog iframe"));
      return {
        html: openedHTML,
        requests: state.captureRequests,
        status: "passed",
      };
    }.toString()})()`,
  );
  for (const kind of ["png", "html"]) {
    const expected = await evaluate(
      `(async()=>{const button=[...document.querySelectorAll('button')].find(b=>b.textContent.trim()===${JSON.stringify("Save " + kind.toUpperCase())});button.click();return Array.from(new Uint8Array(await window.captureFiles[${JSON.stringify(kind)}].arrayBuffer()));})()`,
    );
    let actual: Buffer | undefined;
    for (let i = 0; i < 150; i++) {
      try {
        actual = await readFile(join(downloadDirectory, "page." + kind));
        break;
      } catch {
        await new Promise((r) => setTimeout(r, 30));
      }
    }
    if (!actual || !actual.equals(Buffer.from(expected)))
      throw Error("Downloaded " + kind + " differs from verified original");
  }
  if (requests !== 0) throw Error(`Archive made ${requests} external requests`);
  const shot = await send("Page.captureScreenshot", { format: "png" });
  await writeFile(
    "/tmp/page-archiver-web-viewer.png",
    Buffer.from(shot.data, "base64"),
  );
  console.log(
    JSON.stringify({
      status: result.status,
      artifactRequests: result.requests,
      externalRequests: requests,
      downloadsVerified: 2,
    }),
  );
} finally {
  await send("Page.setDownloadBehavior", { behavior: "default" });
  ws.close();
  sink.close();
  await rm(downloadDirectory, { recursive: true, force: true });
}
