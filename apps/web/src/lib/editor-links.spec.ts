import { expect, test, vi } from 'vitest';
import { cellText, createEditorLinks, singular, slashMatches, type LinkRequest } from './editor-links';

test('table commands use generic English singulars of the table ID', () => {
	expect(
		['people', 'places', 'categories', 'boxes', 'matches', 'status', 'notes', 'tv_shows'].map(
			singular
		)
	).toEqual(['person', 'place', 'category', 'box', 'match', 'status', 'note', 'tv_show']);
});

test('slash queries match command words by prefix and only list tables once typed', () => {
	const tables = [
		{ id: 'people', command: 'person' },
		{ id: 'places', command: 'place' }
	];
	const names = (query: string) =>
		slashMatches(query, tables).map((item) => (item.kind === 'table' ? item.table.id : item.kind));
	expect(names('')).toEqual(['mention', 'view']);
	expect(names('pe')).toEqual(['people']);
	expect(names('person')).toEqual(['people']);
	expect(names('PLACE')).toEqual(['places']);
	expect(names('peo')).toEqual(['people']);
	expect(names('men')).toEqual(['mention']);
	expect(names('view')).toEqual(['view']);
	expect(names('embed')).toEqual(['view']);
	expect(names('zzz')).toEqual([]);
});

function host(replies: Record<string, (args: any) => unknown>) {
	const calls: [string, unknown][] = [];
	const request: LinkRequest = async (op, args) => {
		calls.push([op, args]);
		return replies[op](args) as never;
	};
	return { calls, links: createEditorLinks(request) };
}

test('mentionable tables have a display property and are writable user tables', async () => {
	const { links } = host({
		catalog: () => ({
			tables: [
				{ id: 'people', display: 'full_name', readOnly: false },
				{ id: 'history', display: 'col', readOnly: true },
				{ id: 'logs', display: null, readOnly: false },
				{ id: 'places', display: 'name', readOnly: false }
			],
			properties: [],
			rules: []
		})
	});
	expect(await links.tables()).toEqual([
		{ id: 'people', command: 'person' },
		{ id: 'places', command: 'place' }
	]);
});

test('record search keeps only mentionable tables and never sends empty text', async () => {
	const { links, calls } = host({
		catalog: () => ({
			tables: [{ id: 'people', display: 'full_name', readOnly: false }],
			properties: [],
			rules: []
		}),
		search: () => [
			{ table: 'people', id: 'p1', label: 'Ada', excerpt: '' },
			{ table: 'history', id: 'h1', label: 'h1', excerpt: '' }
		]
	});
	expect(await links.search(undefined, '  ')).toEqual([]);
	expect(calls).toEqual([]);
	expect(await links.search(undefined, 'ada')).toEqual([{ table: 'people', id: 'p1', label: 'Ada' }]);
	await links.search('people', 'ada');
	expect(calls.filter(([op]) => op === 'search').map(([, args]) => args)).toEqual([
		{ text: 'ada', limit: 20 },
		{ text: 'ada', table: 'people', limit: 20 }
	]);
});

test('labels requested together resolve in one core request', async () => {
	const { links, calls } = host({
		mentionLabels: ({ targets }: { targets: { table: string; id: string }[] }) =>
			targets.map((t) => ({ ...t, label: t.id === 'gone' ? null : `Label ${t.id}`, trashed: false }))
	});
	const [a, b] = await Promise.all([links.label('people', 'p1'), links.label('people', 'gone')]);
	expect(a.label).toBe('Label p1');
	expect(b.label).toBeNull();
	expect(calls).toEqual([
		[
			'mentionLabels',
			{
				targets: [
					{ table: 'people', id: 'p1' },
					{ table: 'people', id: 'gone' }
				]
			}
		]
	]);
});

test('relative embeds repeat the read with the host calendar for the view policy', async () => {
	const embed = vi.fn((args: any) =>
		args.calendar
			? { name: 'Due', columns: [], rows: [], more: false }
			: { name: 'Due', columns: [], rows: [], more: false, calendar: { timeZone: 'UTC', dayStartMinutes: 0 } }
	);
	const { links } = host({ viewEmbed: embed });
	expect((await links.embed('items', 'v1')).name).toBe('Due');
	expect(embed).toHaveBeenCalledTimes(2);
	expect(embed.mock.calls[1][0].calendar.start).toMatch(/T00:00:00\.000Z$/);
});

test('views list every saved view without unavailable definitions', async () => {
	const { links, calls } = host({
		listViews: () => ({
			views: [
				{ id: 'v1', name: 'Today', tbl: 'tasks', unavailable: null },
				{ id: 'v2', name: 'Broken', tbl: 'tasks', unavailable: 'bad' }
			],
			unavailable: null
		})
	});
	expect(await links.views()).toEqual([{ table: 'tasks', id: 'v1', name: 'Today' }]);
	expect(calls).toEqual([['listViews', {}]]);
});

test('preview cells render plain text for scalar and multi-select values', () => {
	expect(cellText('Ada', 'text')).toBe('Ada');
	expect(cellText(3, 'int')).toBe('3');
	expect(cellText(1, 'bool')).toBe('Yes');
	expect(cellText(0, 'bool')).toBe('No');
	expect(cellText('["A","B"]', 'multi_select')).toBe('A, B');
	expect(cellText('not json', 'multi_select')).toBe('not json');
	expect(cellText(null, 'text')).toBe('');
});
