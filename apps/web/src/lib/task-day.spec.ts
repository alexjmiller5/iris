import { expect, test } from 'vitest';
import { DatabaseSync } from 'node:sqlite';
import { compileView } from '../../../../packages/core/client.js';
import { queryDefinition } from './view-controls';

test('the real query compiler keeps dated open high-priority work, including project links, until the configured rollover', () => {
	const db = new DatabaseSync(':memory:');
	try {
		db.exec(
			'CREATE TABLE items(id TEXT PRIMARY KEY, due TEXT, priority TEXT, status TEXT, projects TEXT, deleted_at TEXT)'
		);
		const insert = db.prepare('INSERT INTO items VALUES (?,?,?,?,?,?)');
		for (const row of [
			['old', '2026-05-31', 'High', 'To Do', null, null],
			['linked', '2026-06-01', 'High', 'In Progress', '["project-1","project-2"]', null],
			['unlinked', '2026-06-01', 'High', 'To Do', '[]', null],
			['next-date', '2026-06-02', 'High', 'To Do', null, null],
			['late-timed', '2026-06-02T02:59:59.999-04:00', 'High', 'To Do', null, null],
			['at-boundary', '2026-06-02T07:00:00.000Z', 'High', 'To Do', null, null],
			['undated', null, 'High', 'To Do', null, null],
			['finished', '2026-06-01', 'High', 'Done', null, null],
			['low', '2026-06-01', 'Low', 'To Do', null, null],
			['deleted', '2026-06-01', 'High', 'To Do', null, '2026-06-01T12:00:00Z']
		])
			insert.run(...row);
		const before = db.prepare('SELECT * FROM items ORDER BY id').all();
		const definition = {
			version: 2,
			timeZone: 'America/New_York',
			dayStartMinutes: 180,
			filters: [
				{ column: 'priority', op: 'eq' as const, value: 'High' },
				{ column: 'due', op: 'lte' as const, relative: 'today' as const }
			],
			groups: [
				{
					match: 'any' as const,
					filters: [
						{ column: 'status', op: 'eq' as const, value: 'To Do' },
						{ column: 'status', op: 'eq' as const, value: 'In Progress' }
					]
				}
			]
		};
		const properties = [
			{ col: 'due', type: 'date' },
			{ col: 'status', type: 'select' },
			{ col: 'priority', type: 'select' },
			{ col: 'projects', type: 'multi_ref' }
		];
		const rows = (now: string) => {
			const query = compileView(queryDefinition('items', definition, new Date(now)), properties);
			return db
				.prepare(query.sql)
				.all(...query.params)
				.map((row: any) => row.id);
		};
		expect(rows('2026-06-02T06:59:59.999Z')).toEqual(['late-timed', 'linked', 'old', 'unlinked']);
		expect(rows('2026-06-02T07:00:00.000Z')).toEqual([
			'at-boundary',
			'late-timed',
			'linked',
			'next-date',
			'old',
			'unlinked'
		]);
		expect(db.prepare('SELECT * FROM items ORDER BY id').all()).toEqual(before);
	} finally {
		db.close();
	}
});
