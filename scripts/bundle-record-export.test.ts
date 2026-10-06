import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { runInNewContext } from "node:vm";

const command = resolve(import.meta.dir, "bundle-record-export.ts");
async function run(output: string, check = false) {
  const process = Bun.spawn(
    ["bun", command, "--output", output, ...(check ? ["--check"] : [])],
    {
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  return {
    code: await process.exited,
    output:
      (await new Response(process.stdout).text()) +
      (await new Response(process.stderr).text()),
  };
}

test("Swift tests execute a fixture matching the current production native entry", async () => {
  const result = await run(
    resolve(
      import.meta.dir,
      "../packages/LifeKit/Tests/LifeKitTests/Fixtures/record-export.js",
    ),
    true,
  );
  expect(result.code).toBe(0);
});

test("bundle command emits a standalone deterministic native bridge and checks stale output without writing", async () => {
  const scratch = await mkdtemp(join(tmpdir(), "life-ui-export-bundle-"));
  const path = join(scratch, "record-export.js");
  try {
    const built = await run(path);
    expect(built.code).toBe(0);
    const first = await readFile(path, "utf8");
    const context: {
      LifeRecordExport?: {
        serialize: (snapshot: string, options: string) => string;
      };
    } = {};
    runInNewContext(first, context);
    const result = context.LifeRecordExport!.serialize(
      JSON.stringify({
        table: "entries",
        properties: [],
        rows: [],
        scope: "loaded",
        completeness: { rows: "unknown", columns: "full", reasons: [] },
        acquisition: {
          source: "local-replica",
          capturedAt: "2026-01-01T00:00:00Z",
          freshness: "unknown",
          lastSync: null,
          skippedTables: [],
          pendingUiEdits: null,
          rejectedEdits: null,
        },
      }),
      '{"format":"json"}',
    );
    expect(JSON.parse(result).rowCount).toBe(0);
    expect((await run(path, true)).code).toBe(0);
    expect((await run(path)).code).toBe(0);
    expect(await readFile(path, "utf8")).toBe(first);
    await writeFile(path, "stale resource\n");
    const stale = await run(path, true);
    expect(stale.code).not.toBe(0);
    expect(stale.output).toContain("stale");
    expect(await readFile(path, "utf8")).toBe("stale resource\n");
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
});
