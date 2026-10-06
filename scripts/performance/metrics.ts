/** The only disposable origin this harness is allowed to reset. */
export function fixtureOrigin(address: string): string {
  const url = new URL(address);
  if (
    url.origin !== "http://life-ui-performance.localhost:5246" ||
    url.username ||
    url.password ||
    url.pathname !== "/workspace" ||
    !url.searchParams.has("review")
  ) {
    throw new Error("Use the reserved synthetic performance workspace origin");
  }
  return url.origin;
}

export function summarize(values: readonly number[]) {
  if (!values.length || values.some((v) => !Number.isFinite(v) || v < 0))
    throw new Error("Missing or invalid measurements");
  const sorted = [...values].sort((a, b) => a - b);
  const n = sorted.length;
  return {
    count: n,
    min: sorted[0]!,
    median:
      n % 2 ? sorted[(n - 1) / 2]! : (sorted[n / 2 - 1]! + sorted[n / 2]!) / 2,
    p95: sorted[Math.ceil(n * 0.95) - 1]!,
    max: sorted[n - 1]!,
  };
}

export function frames(timestamps: readonly number[]) {
  if (
    timestamps.length < 2 ||
    timestamps.some(
      (v, i) => !Number.isFinite(v) || (i > 0 && v <= timestamps[i - 1]!),
    )
  )
    throw new Error("Need increasing frame timestamps");
  const intervals = timestamps.slice(1).map((v, i) => v - timestamps[i]!);
  return {
    averageFps:
      (intervals.length * 1000) / (timestamps.at(-1)! - timestamps[0]!),
    intervalMs: summarize(intervals),
    intervalsOver60HzBudget: intervals.filter((v) => v > 1000 / 60).length,
  };
}

export interface ResourceSize {
  name: string;
  transferSize: number;
  encodedBodySize: number;
  decodedBodySize: number;
}

export function javascriptBytes(
  resources: readonly ResourceSize[],
  requiredWorkerUrls: readonly string[] = [],
) {
  const js = resources.filter((r) => /\.m?js$/.test(new URL(r.name).pathname));
  if (requiredWorkerUrls.some((url) => !js.some((r) => r.name === url)))
    throw new Error("Missing Worker entry size evidence");
  if (
    !js.length ||
    js.some(
      (r) =>
        !Number.isFinite(r.decodedBodySize) ||
        r.decodedBodySize <= 0 ||
        !Number.isFinite(r.encodedBodySize) ||
        r.encodedBodySize <= 0 ||
        !Number.isFinite(r.transferSize) ||
        r.transferSize < 0,
    )
  )
    throw new Error("Missing JavaScript size evidence");
  return {
    requests: js.length,
    transferBytesIncludingHeaders: js.reduce((s, r) => s + r.transferSize, 0),
    encodedBodyBytes: js.reduce((s, r) => s + r.encodedBodySize, 0),
    decodedBodyBytes: js.reduce((s, r) => s + r.decodedBodySize, 0),
  };
}
