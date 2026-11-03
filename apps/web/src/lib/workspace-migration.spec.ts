import { expect, test } from 'vitest';
import { assertMigrationPreserved, type WorkspaceMigrationSnapshot } from './workspace-migration';
const bytes = (value: unknown) => new TextEncoder().encode(JSON.stringify(value));
function snapshot(): WorkspaceMigrationSnapshot {
	return {
		'database-schema': [{ key: 'schema', value: bytes(['CREATE TABLE synthetic(id,value)']) }],
		'database-values': [
			{
				key: 'row-1',
				value: bytes([{ type: 'integer', value: '9223372036854775807' }, { type: 'null' }])
			},
			{ key: 'row-2', value: bytes([{ type: 'text', value: 'synthetic value' }]) }
		],
		'pending-intents': [
			{
				key: 'intent-1',
				value: bytes({ request: 'opaque-request', operation: 'insert', acknowledged: false })
			}
		],
		'governance-journal': [
			{
				key: 'scope-1',
				value: bytes({
					previewToken: 'synthetic-preview',
					idempotencyKey: 'synthetic-key',
					expectedVersion: 'version-1'
				})
			}
		],
		'changeset-journal': [
			{
				key: 'scope-1',
				value: bytes({
					proposalId: 'opaque-proposal',
					idempotencyKey: 'synthetic-key-2',
					expectedVersion: 'version-2'
				})
			}
		],
		files: [
			{
				key: 'file-1',
				value: bytes({ sha256: '1'.repeat(64), bytes: 42, metadata: { name: 'synthetic.bin' } })
			}
		],
		recents: [{ key: 'recent-1', value: bytes({ label: 'Synthetic workspace' }) }],
		preferences: [],
		credential: [{ key: 'consumer', value: bytes('synthetic scoped credential') }],
		backups: []
	};
}
test('preservation accepts exact values despite enumeration order changes', () => {
	const before = snapshot(),
		after = structuredClone(before);
	after['database-values'].reverse();
	expect(() => assertMigrationPreserved(before, after)).not.toThrow();
});
test('equal row counts cannot conceal changed actual typed values', () => {
	const before = snapshot(),
		after = structuredClone(before);
	after['database-values'][0].value = bytes([
		{ type: 'integer', value: '9223372036854775806' },
		{ type: 'null' }
	]);
	expect(() => assertMigrationPreserved(before, after)).toThrow();
});
test('null, empty text and lost integer precision are not equivalent', () => {
	const before = snapshot();
	for (const value of [
		[{ type: 'integer', value: 9223372036854775807 }, { type: 'null' }],
		[
			{ type: 'integer', value: '9223372036854775807' },
			{ type: 'text', value: '' }
		]
	]) {
		const after = structuredClone(before);
		after['database-values'][0].value = bytes(value);
		expect(() => assertMigrationPreserved(before, after)).toThrow();
	}
});
test.each([
	'pending-intents',
	'governance-journal',
	'changeset-journal',
	'files',
	'credential',
	'recents',
	'database-schema'
] as const)('changed %s values cannot pass on matching counts', (store) => {
	const before = snapshot(),
		after = structuredClone(before);
	after[store][0].value = bytes('changed payload');
	expect(() => assertMigrationPreserved(before, after)).toThrow();
});
test('file metadata changes fail even if the payload hash matches', () => {
	const before = snapshot(),
		after = structuredClone(before);
	after.files[0].value = bytes({
		sha256: '1'.repeat(64),
		bytes: 42,
		metadata: { name: 'changed.bin' }
	});
	expect(() => assertMigrationPreserved(before, after)).toThrow();
});
test('missing store, duplicate identity or renamed records fail closed', () => {
	const before = snapshot();
	const missing = structuredClone(before);
	delete (missing as Partial<WorkspaceMigrationSnapshot>).backups;
	expect(() => assertMigrationPreserved(before, missing)).toThrow();
	const duplicate = structuredClone(before);
	duplicate['database-values'][1].key = 'row-1';
	expect(() => assertMigrationPreserved(before, duplicate)).toThrow();
	const renamed = structuredClone(before);
	renamed.credential[0].key = 'other';
	expect(() => assertMigrationPreserved(before, renamed)).toThrow();
});
test('missing or extra entries cannot pass an otherwise equal inventory', () => {
	const before = snapshot(),
		after = structuredClone(before);
	after.preferences.push({ key: 'unexpected', value: bytes(true) });
	expect(() => assertMigrationPreserved(before, after)).toThrow();
});

test('matching duplicate snapshots are rejected rather than silently collapsing identities', () => {
	const before = snapshot();
	before['database-values'][1].key = 'row-1';
	expect(() => assertMigrationPreserved(before, structuredClone(before))).toThrow();
});
test('changed file hash fails even with identical byte count and metadata', () => {
	const before = snapshot(),
		after = structuredClone(before);
	after.files[0].value = bytes({
		sha256: '2'.repeat(64),
		bytes: 42,
		metadata: { name: 'synthetic.bin' }
	});
	expect(() => assertMigrationPreserved(before, after)).toThrow();
});
