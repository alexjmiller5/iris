const stores = [
	'database-schema',
	'database-values',
	'pending-intents',
	'governance-journal',
	'changeset-journal',
	'files',
	'recents',
	'preferences',
	'credential',
	'backups'
] as const;
type MigrationRecord = { key: string; value: Uint8Array };
export type WorkspaceMigrationSnapshot = Record<(typeof stores)[number], MigrationRecord[]>;
const failed = () => new Error('Workspace migration did not preserve all retained data.');
function inventory(snapshot: WorkspaceMigrationSnapshot) {
	if (
		!snapshot ||
		typeof snapshot !== 'object' ||
		Array.isArray(snapshot) ||
		Object.keys(snapshot).length !== stores.length ||
		stores.some((store) => !Object.hasOwn(snapshot, store))
	)
		throw failed();
	return stores.map((store) => {
		const records = snapshot[store];
		if (!Array.isArray(records)) throw failed();
		const values = new Map<string, Uint8Array>();
		for (const record of records) {
			if (
				!record ||
				typeof record.key !== 'string' ||
				!record.key.length ||
				!(record.value instanceof Uint8Array) ||
				values.has(record.key)
			)
				throw failed();
			values.set(record.key, record.value);
		}
		return values;
	});
}
/** Compare freshly collected, lossless logical bytes from both generations.
 * The host must include actual schema/typed values, complete pending requests,
 * and freshly computed file hashes plus metadata. Counts alone are insufficient.
 * This comparison neither collects data nor proves plaintext cleanup/legacy retirement.
 */
export function assertMigrationPreserved(
	before: WorkspaceMigrationSnapshot,
	after: WorkspaceMigrationSnapshot
): void {
	const original = inventory(before),
		restored = inventory(after);
	for (let i = 0; i < original.length; i++) {
		const expected = original[i],
			actual = restored[i];
		if (expected.size !== actual.size) throw failed();
		for (const [key, value] of expected) {
			const retained = actual.get(key);
			if (
				!retained ||
				retained.length !== value.length ||
				value.some((byte, index) => byte !== retained[index])
			)
				throw failed();
		}
	}
}
