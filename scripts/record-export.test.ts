import { beforeAll, expect, test } from "bun:test";
import { runInNewContext } from "node:vm";
import { resolve } from "node:path";
import {
  serializeExport,
  type ExportArtifact,
  type ExportOptions,
  type ExportSnapshot,
} from "../apps/web/src/lib/export/serialize";

const snapshot: ExportSnapshot = {
  table: "entries",
  properties: [
    { tbl: "entries", col: "body", type: "markdown" },
    { tbl: "entries", col: "empty", type: "text" },
  ],
  rows: [
    {
      id: "e\u0301",
      body: "# Raw\r\n\n_tag_  \n雪",
      empty: "",
      nullable: null,
    },
    { id: "\u00e9", body: "=2+2", empty: null },
  ],
  scope: "loaded",
  completeness: {
    rows: "unknown",
    columns: "full",
    reasons: ["Only loaded rows."],
  },
  acquisition: {
    source: "local-replica",
    capturedAt: "2026-01-01T00:00:00.000Z",
    freshness: "unknown",
    lastSync: null,
    skippedTables: [],
    pendingUiEdits: null,
    rejectedEdits: null,
  },
};

let script: string;
beforeAll(async () => {
  const result = await Bun.build({
    entrypoints: [
      resolve(import.meta.dir, "../apps/web/src/lib/export/native-entry.ts"),
    ],
    target: "browser",
    format: "iife",
  });
  if (!result.success)
    throw new AggregateError(result.logs, "Native export bundle failed");
  script = await result.outputs[0].text();
});

function bridge() {
  const context: {
    IrisRecordExport?: {
      serialize: (snapshot: string, options: string) => string;
    };
  } = {};
  runInNewContext(script, context);
  expect(typeof context.IrisRecordExport?.serialize).toBe("function");
  return context.IrisRecordExport!.serialize;
}
function exported(
  input = snapshot,
  options: ExportOptions = { format: "json" },
): ExportArtifact {
  return JSON.parse(bridge()(JSON.stringify(input), JSON.stringify(options)));
}

test("native boundary retains exact IDs, raw Markdown, null, empty and absent values", () => {
  const artifact = exported();
  expect(artifact.rowCount).toBe(2);
  const data = JSON.parse(artifact.files[0].text);
  expect(data.rows).toEqual([
    {
      id: "e\u0301",
      body: "# Raw\r\n\n_tag_  \n雪",
      empty: "",
      nullable: null,
    },
    { id: "\u00e9", body: "=2+2", empty: null },
  ]);
  expect(data.acquisition).toEqual({
    source: "local-replica",
    capturedAt: "2026-01-01T00:00:00.000Z",
    freshness: "unknown",
    lastSync: null,
    skippedTables: [],
    pendingUiEdits: null,
    rejectedEdits: null,
  });
  expect(data.scope).toEqual({ kind: "loaded", rowCount: 2 });
  expect(data.completeness.rows).toBe("unknown");
});

test("native CSV keeps formula protection and a sidecar from the same capture", () => {
  const artifact = exported(snapshot, { format: "csv" });
  expect(artifact.files).toHaveLength(2);
  expect(artifact.files[0].text).toBe(
    '"id","body","empty","nullable"\r\n' +
      '"e\u0301","# Raw\r\n\n_tag_  \n雪","",\r\n' +
      '"\u00e9","\'=2+2",,\r\n',
  );
  const sidecar = JSON.parse(artifact.files[1].text);
  expect(sidecar.scope).toEqual({ kind: "loaded", rowCount: 2 });
  expect(sidecar.completeness).toEqual(snapshot.completeness);
  expect(sidecar.acquisition).toEqual(snapshot.acquisition);
  expect(sidecar.csv.lossless).toBe(false);
  expect(sidecar).not.toHaveProperty("rows");
});

test.each(["json", "csv"] as const)(
  "native and web %s artifacts have identical bytes",
  (format) => {
    // Cross-boundary parity supplements independently asserted values above.
    expect(exported(snapshot, { format })).toEqual(
      serializeExport(snapshot, { format }),
    );
  },
);

test("empty selection differs from omitted selection and Unicode IDs stay distinct", () => {
  expect(exported(snapshot, { format: "json", selectedIds: [] }).rowCount).toBe(
    0,
  );
  const selected = exported(snapshot, {
    format: "json",
    selectedIds: ["\u00e9"],
  });
  expect(JSON.parse(selected.files[0].text).rows).toEqual([
    { id: "\u00e9", body: "=2+2", empty: null },
  ]);
  for (const selectedIds of [["missing"], ["\u00e9", "\u00e9"]]) {
    expect(() => exported(snapshot, { format: "json", selectedIds })).toThrow(
      /selection/i,
    );
  }
});

test("invalid input throws through the string boundary and does not poison later exports", () => {
  const serialize = bridge();
  expect(() => serialize("{", '{"format":"json"}')).toThrow();
  for (const value of ["-0", "9007199254740992", "1e999"]) {
    const input = JSON.stringify({
      ...snapshot,
      rows: [{ id: "one", value: "REPLACE" }],
    }).replace('"REPLACE"', value);
    expect(() => serialize(input, '{"format":"json"}')).toThrow(/number/i);
  }
  expect(
    JSON.parse(serialize(JSON.stringify(snapshot), '{"format":"json"}'))
      .rowCount,
  ).toBe(2);
});

test("content crosses as data without evaluating its Markdown or quoted IDs", () => {
  const body = "'); globalThis.injected = true; //\n<script>throw 1</script>";
  const result = exported({ ...snapshot, rows: [{ id: '"\\opaque', body }] });
  expect(JSON.parse(result.files[0].text).rows).toEqual([
    { id: '"\\opaque', body },
  ]);
});

test("native boundary refuses false table completeness and duplicate identities", () => {
  expect(() =>
    exported({
      ...snapshot,
      scope: "table",
      completeness: { ...snapshot.completeness, rows: "complete" },
    }),
  ).toThrow(/coverage/i);
  expect(() =>
    exported({ ...snapshot, rows: [{ id: "same" }, { id: "same" }] }),
  ).toThrow(/identity/i);
});
