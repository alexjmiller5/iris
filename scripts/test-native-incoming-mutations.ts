import { mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawn } from 'node:child_process';

const scratchArgument = process.argv[2];
if (!scratchArgument) throw Error('Provide a dedicated SwiftPM scratch/cache root.');
const scratch = resolve(scratchArgument);
const root = resolve(import.meta.dir, '..');
const model = 'packages/IrisKit/Sources/IrisKit/IncomingReferencesModel.swift';
const host = 'packages/IrisKit/Sources/IrisKit/WorkspaceModel.swift';
const bridge = 'packages/IrisKit/Sources/IrisKit/NativeWorkspace.swift';
const mutations = [
  ['wrong-target', bridge, 'CoreRequests.ReferenceSources(args)', 'CoreRequests.ReferenceSources(CoreReferenceSourcesArgs(table: "notes"))'],
  ['wrong-page-size', model, 'limit: 20, offset:', 'limit: 1, offset:'],
  ['wrong-offset', model, 'offset: more ? group.nextOffset : 0', 'offset: more ? 1 : 0'],
  ['duplicate-keeps-old', model, 'rows[position] = row', 'rows[position] = rows[position]'],
  ['stale-source-metadata', model, 'groups[index].source = page.source', '// Keep obsolete metadata'],
  ['lost-retry-offset', model, 'groups[index].error = error.localizedDescription', 'groups[index].nextOffset = nil; groups[index].error = error.localizedDescription'],
  ['duplicate-pending-load', model, 'guard !group.loading,', 'guard true,'],
  ['reload-loaded-group', model, 'group.nextOffset != nil : !group.loaded', 'group.nextOffset != nil : true'],
  ['stale-generation', model, 'generation == version &&', 'true &&'],
  ['ignored-context', model, 'isCurrent() && !Task.isCancelled', 'true && !Task.isCancelled'],
  ['ignored-cancellation', model, '&& !Task.isCancelled', ''],
  ['revived-disposed', model, '!disposed && generation', 'true && generation'],
  ['ignored-catalog', host, 'catalog: catalog, skippedTables:', 'catalog: nil, skippedTables:'],
  ['ignored-coverage', host, 'skippedTables: Set(skippedTables)', 'skippedTables: []'],
  ['ignored-workspace', host, 'workspaceGeneration: workspaceGeneration, table: context.table, rowID: rowID,', 'workspaceGeneration: 0, table: context.table, rowID: rowID,'],
  ['table-round-trip', host, 'self?.viewGeneration == selection\n          && self?.incomingReferencesIdentity', 'self?.incomingReferencesIdentity'],
  ['ignored-editor', host, '== identity && isCurrent()', '== identity'],
  ['normalized-row-key', bridge, 'Data(id.utf8)', 'Data(id.precomposedStringWithCanonicalMapping.utf8)'],
  ['normalized-target-key', model, 'exactRowID = Data(rowID.utf8)', 'exactRowID = Data(rowID.precomposedStringWithCanonicalMapping.utf8)'],
] as const;
const originals = new Map(await Promise.all(
  [...new Set(mutations.map(([, path]) => path))].map(async path => [path, await Bun.file(resolve(root, path)).text()] as const)
));
mkdirSync(resolve(scratch, 'mutations'), { recursive: true });
const command = ['swift', 'test', '--package-path', 'packages/IrisKit',
  '--scratch-path', resolve(scratch, 'build'), '--cache-path', resolve(scratch, 'cache'),
  '--config-path', resolve(scratch, 'config'), '--security-path', resolve(scratch, 'security'),
  '--manifest-cache', 'local', '--jobs', '4', '--filter', 'IncomingReferences'];
for (const [name, path, before, after] of mutations) {
  const original = originals.get(path)!;
  if (original.split(before).length !== 2) throw Error(`Mutation target moved: ${name}`);
  try {
    await Bun.write(resolve(root, path), original.replace(before, after));
    const child = spawn(command[0], command.slice(1), { cwd: root, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, CLANG_MODULE_CACHE_PATH: resolve(scratch, 'clang'),
        SWIFTPM_MODULECACHE_OVERRIDE: resolve(scratch, 'modules') } });
    let out = '', err = '';
    child.stdout!.setEncoding('utf8').on('data', data => { out += data; });
    child.stderr!.setEncoding('utf8').on('data', data => { err += data; });
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      // SwiftPM starts a test helper; terminate this owned process group too.
      if (child.pid) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
    }, 60_000);
    const status = await new Promise<number | null>((resolve, reject) => {
      child.once('error', reject);
      child.once('close', resolve);
    }).finally(() => clearTimeout(timer));
    await Bun.write(resolve(scratch, 'mutations', `${name}.log`), out + err);
    if (timedOut) throw Error(`Mutation timed out without a completed test run: ${name}`);
    if (status === 0) throw Error(`Mutation survived: ${name}`);
    if (!/recorded an issue.*(?:Expectation failed|Issue recorded)/.test(out + err)
      || !/Test run with .* failed/.test(out + err))
      throw Error(`Mutation did not reach a behavior assertion: ${name}`);
    console.log(`CAUGHT: ${name}`);
  } finally {
    await Bun.write(resolve(root, path), original);
  }
}
