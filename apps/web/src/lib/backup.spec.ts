import { describe, expect, it } from 'vitest';
import { backupMessage, downloadHubBackup, formatBytes, restoreRows } from './backup';

const summary = (tables: [string, number, number, string | null][]) => ({
	version: 1,
	rows: 0,
	newestUpdatedAt: null,
	schemaEntries: 0,
	tables: tables.map(([table, rows, liveRows, newestUpdatedAt]) => ({
		table,
		rows,
		liveRows,
		newestUpdatedAt
	}))
});

describe('restore preview rows', () => {
	it('lists every table on either side with what restoring does to it', () => {
		const rows = restoreRows(
			summary([
				['notes', 3, 2, 'b'],
				['people', 1, 1, 'a'],
				['places', 4, 4, 'c']
			]),
			summary([
				['notes', 3, 2, 'b'],
				['people', 2, 2, 'z'],
				['scratch', 9, 9, null]
			])
		);
		expect(rows.map((r) => [r.table, r.change, r.backupRows, r.currentRows])).toEqual([
			['notes', 'same', 3, 3],
			['people', 'changed', 1, 2],
			['places', 'added', 4, null],
			['scratch', 'removed', null, 9]
		]);
	});
});

describe('hub backup download', () => {
	const backup = {
		key: 'daily/life-2026-10-08T09-10-00.sql.gz',
		taken_at: '2026-10-08T09:12:00.000Z',
		bytes: 3,
		sha256: '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81'
	};
	const connection = { endpoint: 'https://hub.test/', token: 'secret' };
	it('fetches the listed key with the credential and checks size and checksum', async () => {
		const calls: [string, RequestInit][] = [];
		const blob = await downloadHubBackup(connection, backup, (async (
			url: string,
			init: RequestInit
		) => {
			calls.push([url, init]);
			return new Response(new Uint8Array([1, 2, 3]));
		}) as typeof fetch);
		expect(calls[0][0]).toBe('https://hub.test/v1/backups/daily/life-2026-10-08T09-10-00.sql.gz');
		expect(calls[0][1].headers).toEqual({ Authorization: 'Bearer secret' });
		expect(calls[0][1].redirect).toBe('error');
		expect(new Uint8Array(await blob.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]));
	});
	it('refuses damaged or partial bytes and keys outside the backup namespace', async () => {
		const reply = (bytes: number[]) =>
			(async () => new Response(new Uint8Array(bytes))) as unknown as typeof fetch;
		await expect(downloadHubBackup(connection, backup, reply([1, 2, 4]))).rejects.toThrow(
			'checksum'
		);
		await expect(downloadHubBackup(connection, backup, reply([1, 2]))).rejects.toThrow(
			'incomplete'
		);
		await expect(
			downloadHubBackup(connection, { ...backup, key: '../auth.sql.gz' }, reply([1, 2, 3]))
		).rejects.toThrow('invalid hub backup key');
	});
});

it('formats sizes and explains hub refusals', () => {
	expect([formatBytes(512), formatBytes(1_500), formatBytes(50_009_310)]).toEqual([
		'512 bytes',
		'1.5 KB',
		'50 MB'
	]);
	expect(backupMessage(new Error('hub HTTP 429'))).toContain('once an hour');
	expect(backupMessage(new Error('hub HTTP 403'))).toContain('cannot use hub backups');
});
