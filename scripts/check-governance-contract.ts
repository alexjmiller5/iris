import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

// Export only committed owner source into a disposable directory. Never mutate
// another checkout, generated bundles, a real database or credentials.
const source = process.env.LIFE_DATA_CONTRACT_ROOT;
if (!source) throw new Error('Set LIFE_DATA_CONTRACT_ROOT to a Life Data Git checkout. See docs/governance-contract.md.');
const prerequisite = '9121ef66df4dcc3a72c63f87d400a8e9555c17f9';
const scratch = mkdtempSync(join(tmpdir(), 'life-governance-'));
const testFile = resolve(import.meta.dir, 'governance-contract.test.ts');
function run(pattern?: string) {
  const result = spawnSync(process.execPath, ['test', testFile, ...(pattern ? ['--test-name-pattern', pattern] : [])], {
    env: { ...process.env, LIFE_DATA_CONTRACT_ROOT: scratch }, encoding: 'utf8',
  });
  if (result.error || result.signal || result.status === null) throw result.error ?? new Error(`Test runner terminated: ${result.signal}`);
  return { status: result.status, output: result.stdout + result.stderr };
}
try {
  const archivePath = join(scratch, 'source.tar');
  execFileSync('git', ['-C', source, 'archive', '--output', archivePath, prerequisite, 'worker', 'core']);
  execFileSync('tar', ['-xf', archivePath, '-C', scratch]);
  const baseline = run();
  process.stdout.write(baseline.output);
  if (baseline.status !== 0) throw new Error('Pinned prerequisite failed conformance before mutation.');
  if (process.argv.includes('--mutations')) {
    const path = join(scratch, 'worker/src/patch.js');
    const original = readFileSync(path, 'utf8');
    const mutations = [
      { name: 'ignore updated_at precondition', from: 'before.updated_at !== revision.updated_at', to: 'false', test: 'only updated_at advanced' },
      { name: 'ignore hub_at precondition', from: '(before.hub_at ?? null) !== revision.hub_at', to: 'false', test: 'only hub_at advanced' },
      { name: 'omit enforced invariants', from: 'const rules=await enforcedRules(view,table);', to: 'const rules=[];', test: 'enforced invariant rolls back' },
      { name: 'leak a value in a write-only receipt', from: 'return {id:row.id,revision:', to: 'return {value:before.name,id:row.id,revision:', test: 'exact table writer gets only a revision receipt' },
      { name: 'erase retained history', from: 'const rules=await enforcedRules(view,table);', to: 'await db.prepare("DELETE FROM history").run(); const rules=await enforcedRules(view,table);', test: 'selected-change inverse preserves' },
    ];
    for (const mutation of mutations) {
      if (original.split(mutation.from).length !== 2) throw new Error(`Mutation target drift: ${mutation.name}`);
      writeFileSync(path, original.replace(mutation.from, mutation.to));
      const result = run(mutation.test);
      writeFileSync(path, original);
      if (result.status === 0 || !result.output.includes('(fail)') || result.output.includes('Unhandled error')) {
        process.stdout.write(result.output);
        throw new Error(`Mutation was not killed by an assertion: ${mutation.name}`);
      }
      console.log(`KILLED: ${mutation.name}`);
    }
    const restored = run();
    if (restored.status !== 0) { process.stdout.write(restored.output); throw new Error('Restored source failed conformance.'); }
    console.log('Restored pinned source passes conformance.');
  }
  console.log(`Life Data prerequisite tested: ${prerequisite}`);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
