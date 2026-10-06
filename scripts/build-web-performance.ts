import { mkdir, writeFile, unlink, rmdir } from "node:fs/promises";
import { resolve } from "node:path";

// Only the disposable production build contains this route. Never deploy it.
const root = resolve(import.meta.dir, "..");
const route = resolve(root, "apps/web/src/routes/performance-grid");
await mkdir(route); // Refuse to overwrite any existing route.
try {
  await writeFile(
    resolve(route, "+page.svelte"),
    '<script>import Grid from "../../../../../scripts/performance/Grid.svelte";</script><Grid />\n',
    { flag: "wx" },
  );
  const build = Bun.spawn(["bun", "run", "build"], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  });
  if ((await build.exited) !== 0)
    throw new Error("Performance fixture production build failed");
} finally {
  await unlink(resolve(route, "+page.svelte")).catch(() => {});
  await rmdir(route);
}
