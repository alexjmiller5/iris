import { describe, expect, it } from 'vitest';
import type { Property } from 'iris-core/client';
import { chipValues, dateText, flagValue, isFlag, jsonText, markdownPreview } from './cell-values';

const prop = (type: string, options?: string[]): Property =>
	({ tbl: 'items', col: 'c', type, options: options?.map((v) => ({ v })) }) as Property;

describe('flag cells', () => {
	it('treats Booleans and 0/1-only ints as flags, nothing else', () => {
		expect(isFlag(prop('bool'))).toBe(true);
		expect(isFlag(prop('int', ['0', '1']))).toBe(true);
		expect(isFlag(prop('int', ['1', '0']))).toBe(true);
		for (const p of [
			prop('int'),
			prop('int', ['0', '1', '2']),
			prop('int', ['1']),
			prop('number', ['0', '1']),
			prop('select', ['0', '1'])
		])
			expect(isFlag(p)).toBe(false);
	});

	it('reads stored integers, reals, strings and booleans', () => {
		for (const yes of [1, 1.0, '1', '1.0', true, 'true']) expect(flagValue(yes)).toBe(true);
		for (const no of [0, 0.0, '0', '0.0', false, 'false']) expect(flagValue(no)).toBe(false);
		for (const empty of [null, undefined, '', 2, 'yes']) expect(flagValue(empty)).toBeNull();
	});
});

describe('json cells', () => {
	it('shows a list of scalars as chips', () => {
		expect(chipValues(prop('json'), '["Alpha", "Beta", 3, true]')).toEqual([
			'Alpha',
			'Beta',
			'3',
			'true'
		]);
		expect(chipValues(prop('json'), '[]')).toEqual([]);
	});

	it('keeps select chips and refuses everything else', () => {
		expect(chipValues(prop('select'), 'To Do')).toEqual(['To Do']);
		expect(chipValues(prop('multi_select'), '["A","B"]')).toEqual(['A', 'B']);
		for (const value of ['{"a":1}', '[{"a":1}]', '[["x"]]', 'not json', '"text"', null])
			expect(chipValues(prop('json'), value)).toBeNull();
		expect(chipValues(prop('text'), '["A"]')).toBeNull();
	});

	it('reads objects as key: value text and nested lists as counts', () => {
		expect(jsonText('{"checking": 12.5, "note": "ok", "inner": {"a": [1]}}')).toBe(
			'checking: 12.5, note: ok, inner: {"a":[1]}'
		);
		expect(jsonText('{"cover": null, "kind": "list"}')).toBe('kind: list');
		expect(jsonText('[{"a":1},{"b":2}]')).toBe('2 items');
		expect(jsonText('[{"a":1}]')).toBe('1 item');
		expect(jsonText('{}')).toBe('');
		expect(jsonText('"plain"')).toBe('plain');
		expect(jsonText('42')).toBe('42');
		expect(jsonText('not json {')).toBe('not json {');
	});
});

describe('markdown previews', () => {
	it('flattens Notion tags, callouts and empty blocks to their text', () => {
		expect(
			markdownPreview(
				'<callout icon="x" color="gray_bg">\n\t**Rules applied**\n\tEarlier entries win.\n</callout>\n<empty-block/>\nAfter'
			)
		).toBe('Rules applied Earlier entries win. After');
		expect(
			markdownPreview('<details>\n<summary>Packing</summary>\n\t- Shirt\n\t- Shoes\n</details>')
		).toBe('Packing Shirt Shoes');
		expect(
			markdownPreview('See <mention-page url="https://example.com/p">Plan</mention-page>.')
		).toBe('See Plan.');
		expect(markdownPreview('<file src="https://example.com/a.pdf">Receipt</file> kept')).toBe(
			'Receipt kept'
		);
	});

	it('keeps mention and embed labels, never link targets', () => {
		expect(
			markdownPreview(
				'Ask [Person One](iris://table/people/row/abc) about [Weekly](iris://table/tasks/view/v1) and [docs](https://example.com).'
			)
		).toBe('Ask Person One about Weekly and docs.');
		expect(markdownPreview('![Chart](https://example.com/c.png) below')).toBe('Chart below');
	});

	it('removes Markdown syntax marks but keeps words with underscores', () => {
		expect(
			markdownPreview(
				'# Title\n\n> quoted **bold** _it_ ~~gone~~ `code`\n1. one\n- [x] done\n---\nsnake_case_name'
			)
		).toBe('Title quoted bold it gone code one done snake_case_name');
		expect(markdownPreview('| a | b |\n| --- | --- |\n| 1 | 2 |')).toBe('a b 1 2');
		expect(markdownPreview('```js\nconst x = 1;\n```')).toBe('const x = 1;');
		expect(markdownPreview('Fish &amp; chips &lt;3&gt;<br>next')).toBe('Fish & chips <3> next');
	});

	it('bounds long sources', () => {
		const preview = markdownPreview('word '.repeat(500));
		expect(preview.length).toBeLessThanOrEqual(281);
		expect(preview.endsWith('…')).toBe(true);
		expect(markdownPreview('')).toBe('');
	});
});

describe('date cells', () => {
	it('reads dates and UTC timestamps like the native apps', () => {
		expect(dateText('date', '2026-10-10', 'en-US')).toBe('Oct 10, 2026');
		expect(dateText('datetime', '2026-10-10T01:17:51.954Z', 'en-US')).toBe(
			'Oct 10, 2026, 1:17 AM UTC'
		);
		expect(dateText('date_or_datetime', '2026-02-28', 'en-US')).toBe('Feb 28, 2026');
		expect(dateText('date_or_datetime', '2026-02-28T23:59:00.000Z', 'en-US')).toBe(
			'Feb 28, 2026, 11:59 PM UTC'
		);
	});

	it('leaves impossible or unexpected source as stored', () => {
		for (const [type, value] of [
			['date', '2024-02-30'],
			['date', 'soon'],
			['datetime', '2026-10-10 01:17'],
			['date', '2026-10-10T01:17:51.954Z'],
			['text', '2026-10-10']
		])
			expect(dateText(type, value, 'en-US')).toBeNull();
	});
});
