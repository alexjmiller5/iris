import { resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const web = resolve(import.meta.dir, "../apps/web");
const output = resolve(web, ".svelte-kit/output");
const load = (file: string) =>
  import(pathToFileURL(resolve(output, "server", file)).href);
const { Server } = await load("index.js");
const { manifest } = await load("manifest.js");
const { set_assets } = await load("internal.js");
set_assets("");
const app = new Server(manifest);
await app.init({ env: {} });
const origin = "http://iris-performance.localhost:5246";

// Fixture-only transport: production SSR sees HTTPS, as it would at the edge.
// Browser localhost is a secure context for OPFS. Never expose this server.
Bun.serve({
  hostname: "127.0.0.1",
  port: 5246,
  async fetch(request) {
    const url = new URL(request.url);
    if (url.origin !== origin || request.method !== "GET")
      return new Response("Fixture GET only", { status: 403 });
    let response: Response | undefined;
    for (const dir of [resolve(output, "client"), resolve(web, "static")]) {
      const path = resolve(dir, "." + decodeURIComponent(url.pathname));
      if (!path.startsWith(dir + sep)) continue;
      const file = Bun.file(path);
      if ((await file.exists()) && file.size) {
        response = new Response(file);
        break;
      }
    }
    if (!response) {
      url.protocol = "https:";
      response = await app.respond(new Request(url, request), {
        getClientAddress: () => "127.0.0.1",
      });
    }
    if (!(response instanceof Response))
      throw new Error("Production SSR returned no response");
    // Applies to document, scripts, Worker imports and WASM, without touching
    // another origin's cache or the shared browser's global network settings.
    response.headers.set("Cache-Control", "no-store");
    response.headers.set("X-Iris-Performance", "production-fixture");
    return response;
  },
});
console.log(`Synthetic production fixture at ${origin}`);
