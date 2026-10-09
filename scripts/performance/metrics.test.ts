import { describe, expect, test } from "bun:test";
import { fixtureOrigin, summarize, frames, javascriptBytes } from "./metrics";

describe("performance evidence", () => {
  test("rejects live, ambiguous, and unrelated origins before any storage reset", () => {
    expect(
      fixtureOrigin(
        "http://iris-performance.localhost:5246/workspace?review",
      ),
    ).toBe("http://iris-performance.localhost:5246");
    for (const url of [
      "https://example.com/workspace?review",
      "http://localhost:5246/workspace?review",
      "http://iris-performance.localhost:5173/workspace?review",
      "http://iris-performance.localhost:5246/workspace",
      "http://user@iris-performance.localhost:5246/workspace?review",
    ]) {
      expect(() => fixtureOrigin(url)).toThrow();
    }
  });
  test("keeps the slow tail and does not mutate measurements", () => {
    const values = [100, 10, 30, 20];
    expect(summarize(values)).toEqual({
      count: 4,
      min: 10,
      median: 25,
      p95: 100,
      max: 100,
    });
    expect(values).toEqual([100, 10, 30, 20]);
    for (const bad of [[], [NaN], [-1], [Infinity]])
      expect(() => summarize(bad)).toThrow();
  });
  test("frame cadence includes stalls and uses intervals rather than sample count", () => {
    const result = frames([0, 10, 20, 120]);
    expect(result.averageFps).toBe(25);
    expect(result.intervalMs).toEqual({
      count: 3,
      min: 10,
      median: 10,
      p95: 100,
      max: 100,
    });
    expect(result.intervalsOver60HzBudget).toBe(1);
    for (const bad of [[], [0], [0, 0], [20, 10], [0, NaN]])
      expect(() => frames(bad)).toThrow();
  });
  test("separates transferred, compressed and decoded JS, including worker entries", () => {
    expect(
      javascriptBytes([
        {
          name: "https://fixture/app.js",
          transferSize: 110,
          encodedBodySize: 90,
          decodedBodySize: 500,
        },
        {
          name: "https://fixture/worker.js?v=1",
          transferSize: 210,
          encodedBodySize: 190,
          decodedBodySize: 800,
        },
        {
          name: "https://fixture/cached.mjs",
          transferSize: 0,
          encodedBodySize: 20,
          decodedBodySize: 100,
        },
        {
          name: "https://fixture/core.wasm",
          transferSize: 500,
          encodedBodySize: 480,
          decodedBodySize: 800,
        },
      ]),
    ).toEqual({
      requests: 3,
      transferBytesIncludingHeaders: 320,
      encodedBodyBytes: 300,
      decodedBodyBytes: 1400,
    });
    expect(() => javascriptBytes([])).toThrow();
    expect(() =>
      javascriptBytes(
        [
          {
            name: "https://fixture/a.js",
            transferSize: 20,
            encodedBodySize: 10,
            decodedBodySize: 15,
          },
        ],
        ["https://fixture/worker.js"],
      ),
    ).toThrow();
    expect(() =>
      javascriptBytes([
        {
          name: "https://fixture/a.js",
          transferSize: 0,
          encodedBodySize: 0,
          decodedBodySize: 0,
        },
      ]),
    ).toThrow();
  });
});
