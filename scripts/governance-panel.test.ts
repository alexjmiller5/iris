import { createRequire } from 'node:module';
const webDependency = createRequire(new URL('../apps/web/package.json', import.meta.url)).resolve;
import { expect, test } from 'bun:test';
import { plugin } from 'bun';
const { compile } = await import(webDependency('svelte/compiler')) as typeof import('svelte/compiler');
const { render } = await import(webDependency('svelte/server')) as typeof import('svelte/server');
import { displayCell } from '../apps/web/src/lib/governance/value';

plugin({ name: 'governance-svelte-ssr', setup(build) {
  build.onLoad({ filter: /\.svelte$/ }, async ({ path }) => {
    const source = await Bun.file(path).text();
    const { js, warnings } = compile(source, { filename: path, generate: 'server' });
    const errors = warnings.filter(warning => warning.code.startsWith('a11y_'));
    if (errors.length) throw new Error(errors.map(error => error.message).join('\n'));
    return { contents: js.code, loader: 'js' };
  });
} });
const { default: Panel } = await import('../apps/web/src/lib/governance/GovernancePanel.svelte');
const { default: Diff } = await import('../apps/web/src/lib/governance/ChangeDiff.svelte');

test('an unavailable canonical API cannot render a working approval action', () => {
  const html = render(Panel, { props: {
    api: null, journal: null, online: true,
    scope: { deploymentId: 'deployment-1', sessionId: 'session-1', principalId: 'user-1' },
    target: { table: 'items', rowId: 'a' },
  } }).body;
  expect(html).toContain('This connection does not offer historical review or proposals.');
  expect(html).not.toContain('Approve online');
  expect(html).not.toContain('Resolve retained approval');
});

test('the diff renders typed values exactly and never executes saved markup', () => {
  const html = render(Diff, { props: { changes: [
    { column: 'quantity', before: { type: 'integer', value: '9223372036854775807' }, after: { type: 'null' } },
    { column: 'body', before: { type: 'text', value: '<script>bad()</script>' }, after: { type: 'text', value: '' } },
  ] } }).body;
  expect(html).toContain('9223372036854775807');
  expect(html).toContain('Empty (NULL)');
  expect(html).toContain('Empty text');
  expect(html).not.toContain('<script>bad()');
  expect(html).toContain('&lt;script>');
});

test('unknown history, SQL null, empty text and numeric zero remain distinguishable', () => {
  expect([null, { type: 'null' }, { type: 'text', value: '' }, { type: 'integer', value: '0' }, { type: 'real', value: 0 }].map(value => displayCell(value as Parameters<typeof displayCell>[0]))).toEqual(['Not recorded', 'Empty (NULL)', 'Empty text', '0', '0']);
});
