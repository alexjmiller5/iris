/** Use two explicitly allocated, disposable browser targets. Never discovers or creates a target.
 * bun scripts/check-governance-browser.ts --target <owned-id> --peer <owned-id> [--port 9222]
 * The driver serves only synthetic fixtures, removes its test database and closes its sockets/server.
 * The caller owns and closes the two tabs/group. No dependency install or service credential needed.
 */
import { strict as assert } from 'node:assert';
import { parseArgs } from 'node:util';
const { values } = parseArgs({ args: Bun.argv.slice(2), options: { target: { type: 'string' }, peer: { type: 'string' }, port: { type: 'string', default: '9222' }, helper: { type: 'string' } } });
if (!values.target || !values.peer || values.target === values.peer) throw new Error('Two distinct owned target IDs are required');
const helper = values.helper;
if (!helper) throw new Error('--helper must name the existing chrome-control cdp-eval.mjs');
function connect(id: string) {
  async function evaluate(expression: string) {
    // Reuse the installed explicit-target bridge. Bridge failures never count as expected app failures.
    const child = Bun.spawn(['node', helper!, values.port!, '-', '--target', id], {
      stdin: new Blob([`(async()=>JSON.stringify({value:await (${expression})}))()`]), stdout: 'pipe', stderr: 'pipe'
    });
    const [output, error, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    if (code) throw new Error(`Browser bridge failed (${code}): ${error}`);
    return JSON.parse(output).value;
  }
  return { evaluate };
}
const build = await Bun.build({ entrypoints: ['scripts/governance-journal-browser.ts'], target: 'browser', plugins: process.env.GOVERNANCE_JOURNAL_SOURCE ? [{ name: 'journal-mutation', setup(builder) { builder.onLoad({ filter: /\/approval-journal\.ts$/ }, async () => ({ contents: await Bun.file(process.env.GOVERNANCE_JOURNAL_SOURCE!).text(), loader: 'ts' })); } }] : [] });
if (!build.success) throw new Error(build.logs.join('\n'));
const script = await build.outputs[0]!.text();
const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch(request) { return new URL(request.url).pathname === '/fixture.js' ? new Response(script, { headers: { 'content-type': 'text/javascript' } }) : new Response('<!doctype html><title>Governance journal boundary test</title><p>Synthetic journal tests. No service connection.</p><script type="module" src="/fixture.js"></script>', { headers: { 'content-type': 'text/html' } }); } });
const database = 'life-ui-governance-test-' + crypto.randomUUID();
const url = `${server.url}?database=${database}`;
const clients: Awaited<ReturnType<typeof connect>>[] = [];
let checks = 0;
const check = (name: string, fn: () => Promise<void>) => fn().then(() => { checks++; console.log(`PASS ${name}`); });
async function ready(client: Awaited<ReturnType<typeof connect>>) {
  for (let attempt = 0; attempt < 100; attempt++) { if (await client.evaluate('!!window.journalHarness')) return; await Bun.sleep(25); }
  throw new Error('Browser fixture did not load');
}
const h = 'window.journalHarness';
try {
  clients.push(connect(values.target), connect(values.peer));
  const [a, b] = clients;
  await Promise.all(clients.map(async client => { await client.evaluate(`(setTimeout(()=>location.assign(${JSON.stringify(url)}),0),true)`); await ready(client); await client.evaluate(`${h}.open()`); }));
  await check('strict transaction completes before retain resolves', async () => { assert.deepEqual(await a!.evaluate(`${h}.retentionOrder()`), ['complete', 'retained']); });
  const original = await a!.evaluate(`${h}.load()`);
  await check('second tab reads exact retained binding', async () => { assert.deepEqual(await b!.evaluate(`${h}.load()`), original); });
  await check('reload restores exact bytes and same key', async () => { await a!.evaluate('(setTimeout(()=>location.reload(),0),true)'); await Bun.sleep(100); await ready(a!); await a!.evaluate(`${h}.open()`); assert.deepEqual(await a!.evaluate(`${h}.load()`), original); });
  await check('identical two-client retries retain the same entry', async () => { assert.deepEqual(await Promise.all(clients.map(c => c.evaluate(`${h}.retain()`))), ['retained', 'retained']); });
  await check('wrong compare-delete preserves unresolved request', async () => { assert.equal(await a!.evaluate(`${h}.resolve({...${h}.entry,request:{...${h}.entry.request,idempotencyKey:'wrong'}}).then(()=>false,()=>true)`), true); assert.deepEqual(await b!.evaluate(`${h}.load()`), original); });
  await a!.evaluate(`${h}.resolve()`);
  await check('two-client different-request race has exactly one winner', async () => {
    const outcomes = await Promise.all(clients.map((c, i) => c.evaluate(`${h}.retain({...${h}.entry,request:{...${h}.entry.request,idempotencyKey:'race-${i}'}}).then(()=>true,()=>false)`)));
    assert.equal(outcomes.filter(Boolean).length, 1);
    const winner = await a!.evaluate(`${h}.load()`); assert.deepEqual(await b!.evaluate(`${h}.load()`), winner);
    await a!.evaluate(`${h}.resolve(${JSON.stringify(winner)})`);
  });
  await check('replacement session cannot adopt or erase old request', async () => {
    await a!.evaluate(`${h}.retain()`); await b!.evaluate(`${h}.open('new',{...${h}.entry.scope,sessionId:'new-session'})`);
    assert.equal(await b!.evaluate(`${h}.load('new')`), null);
    assert.equal(await b!.evaluate(`${h}.retain(${h}.entry,'new').then(()=>false,()=>true)`), true); assert.equal(await b!.evaluate(`${h}.resolve(${h}.entry,'new').then(()=>false,()=>true)`), true);
    assert.deepEqual(await a!.evaluate(`${h}.load()`), original); await a!.evaluate(`${h}.resolve()`);
  });
  await check('quota failure leaves no dispatchable retained entry', async () => { assert.equal(await a!.evaluate(`${h}.fault('quota').then(()=>false,()=>true)`), true); assert.equal(await a!.evaluate(`${h}.load()`), null); });
  await check('unsupported strict durability rejects opening', async () => { assert.equal(await a!.evaluate(`${h}.fault('durability').then(()=>false,()=>true)`), true); });
  await check('corrupt and unknown-version entries cannot be overwritten or deleted', async () => {
    for (const value of ['broken-json', JSON.stringify({ ...original, version: 99 })]) {
      await a!.evaluate(`${h}.corrupt(${JSON.stringify(value)})`);
      for (const method of ['load()', 'retain()', 'resolve()']) assert.equal(await b!.evaluate(`${h}.${method}.then(()=>false,()=>true)`), true);
    }
  });
  console.log(`${checks} real-browser journal checks passed`);
} finally {
  for (const client of clients) { try { await client.evaluate(`${h}.close()`); } catch {} }
  try { await clients[0]?.evaluate(`${h}.remove()`); } finally { server.stop(true); }
}
