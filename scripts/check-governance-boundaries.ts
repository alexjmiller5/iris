/** Pure presentation/codec mutation checks. Real IndexedDB race mutations require the browser runner. */
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
const root = resolve(import.meta.dir, '..');
const tests = ['scripts/governance-approval.test.ts', 'scripts/governance-journal.test.ts', 'scripts/governance-list.test.ts', 'scripts/governance-panel.test.ts'];
const directory = await mkdtemp(join(root, 'apps/web/src/lib/governance/.boundary-mutations-'));
const cases = [
  { name: 'comma-key corruption accepted', file: 'approval-journal.ts', before: "Object.keys(value).length === expected.length &&\n\texpected.every((key) => Object.hasOwn(value, key))", after: "Object.keys(value).sort().join(',') === [...expected].sort().join(',')" },
  { name: 'cross-session journal adoption', file: 'approval-journal.ts', before: 'scopeKey(value.scope) !== scopeKey(scope)', after: 'false' },
  { name: 'old approval refreshes replacement context', file: 'proposal-review.ts', before: "result.kind === 'success' && !disposed && current === generation", after: "result.kind === 'success'" },
  { name: 'approval dispatches before durable retain', file: 'proposal-review.ts', before: 'await journal.retain(structuredClone(pending));', after: 'void journal.retain(structuredClone(pending)).catch(() => {});' },
  { name: 'unresolved rejection settles original request', file: 'proposal-review.ts', before: "result.resolution === 'not_committed'", after: "result.resolution === 'unresolved'" },
  { name: 'malformed approval envelope bypasses guard', file: 'proposal-review.ts', before: 'result = approvalResult(received)', after: 'result = true' },
  { name: 'missing error resolution accepted', file: 'proposal-review.ts', before: "oneOf(value.resolution, ['unresolved', 'not_committed'])", after: 'true' },
  { name: 'receipt version binding ignored', file: 'proposal-review.ts', before: 'result.value.proposalVersion !== retained.request.expectedVersion', after: 'false' },
  { name: 'retry silently replaces idempotency key', file: 'proposal-review.ts', before: 'const sent = { ...retained.request };', after: 'const sent = { ...retained.request, idempotencyKey: crypto.randomUUID() };' },
  { name: 'replayed receipt incorrectly requires history', file: 'proposal-review.ts', before: 'strings(receipt.historyEventIds) &&', after: 'strings(receipt.historyEventIds) && receipt.historyEventIds.length > 0 &&' },
  { name: 'successful retry retains obsolete rejection feedback', file: 'proposal-review.ts', before: 'receipt: result.value, conflicts: [], contentUnavailable: false', after: 'receipt: result.value' },
  { name: 'late page resurrects purged content', file: 'review-list.ts', before: 'if (disposed || current !== generation) return;', after: 'if (disposed) return;' },
];
async function run(env: Record<string,string> = {}) {
  const child = Bun.spawn(['bun', 'test', ...tests], { cwd: root, env: { ...process.env, ...env }, stdout: 'pipe', stderr: 'pipe' });
  const [out, err, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  return { output: out + err, code };
}
try {
  const baseline = await run(); if (baseline.code) throw new Error(baseline.output);
  for (const mutant of cases) {
    const path = join(root, 'apps/web/src/lib/governance', mutant.file);
    const original = await Bun.file(path).text();
    if (!original.includes(mutant.before)) throw new Error('Mutation no longer matches: ' + mutant.name);
    const contents = original.replaceAll(mutant.before, mutant.after);
    const mutated = join(directory, mutant.file);
    await writeFile(mutated, contents);
    const variable = mutant.file === 'approval-journal.ts' ? 'LIFE_UI_TEST_APPROVAL_JOURNAL' : mutant.file === 'proposal-review.ts' ? 'LIFE_UI_TEST_PROPOSAL_REVIEW' : 'LIFE_UI_TEST_REVIEW_LIST';
    const result = await run({ [variable]: mutated });
    if (!result.code || !result.output.includes('(fail)')) throw new Error(`Mutation survived or failed outside an assertion: ${mutant.name}\n${result.output}`);
    console.log('KILLED ' + mutant.name);
  }
  const restored = await run(); if (restored.code) throw new Error(restored.output);
  console.log(`${cases.length} mutants killed; unmodified source green`);
} finally { await rm(directory, { recursive: true, force: true }); }
