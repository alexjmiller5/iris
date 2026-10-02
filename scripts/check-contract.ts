import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { generateContract } from '../packages/core/contract/generate-core-contract.ts';
import { CORE_CONTRACT_HASH } from '../packages/core/client.js';

const root = resolve(import.meta.dir, '..');
const schema = JSON.parse(await readFile(resolve(root, 'packages/core/contract/core.json'), 'utf8'));
const generated = generateContract(schema);
for (const [file, content] of [
  ['packages/core/contract.generated.ts', generated.typescript],
  ['packages/LifeKit/Sources/LifeKit/Generated/CoreContract.generated.swift', generated.swift],
]) {
  if (await readFile(resolve(root, file), 'utf8') !== content) throw new Error(`Stale generated contract: ${file}`);
}
if (CORE_CONTRACT_HASH !== generated.hash) throw new Error('Client bundle and generated contract disagree.');
console.log(`Core contract verified: ${generated.hash}`);
