import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { strict as assert } from 'node:assert';

// Changing an unrelated web component must not change the embedded native islands.
const web = resolve(import.meta.dir, '../apps/web');
const scratch = await mkdtemp(join(tmpdir(), 'iris-island-builds-'));
const probe = join(web, 'src', `island-build-probe-${crypto.randomUUID()}.svelte`);
async function run(args: string[]) {
 const child = Bun.spawn(['bun', 'x', '--no-install', ...args], {cwd:web,stdout:'pipe',stderr:'pipe'});
 const [output, errors, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
 if (code) throw Error(output+errors);
}
async function build(island: string, phase: string) {
 const output = join(scratch, `${island}-${phase}`);
 await run(['vite','build','--config',`vite.${island}.config.ts`,'--outDir',output]);
 return await readFile(join(output,`${island}.html`),'utf8');
}
try {
 await run(['svelte-kit','sync']);
 const before = new Map<string,string>();
 for (const island of ['editor','graph']) before.set(island, await build(island,'before'));
 await writeFile(probe, '<p class="rotate-[23.456deg] bg-[#abc123]">Unrelated web page</p>\n');
 for (const island of ['editor','graph']) {
  const after=await build(island,'after');
  assert.equal(after === before.get(island), true, `${island} changed when an unrelated web component was added`);
 }
 console.log('PASS: native editor and graph artifacts ignore unrelated web sources');
} finally {
 await rm(probe,{force:true});
 await rm(scratch,{recursive:true,force:true});
}
