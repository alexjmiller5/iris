import { collectSQLiteInventory, type SQLiteInventoryDriver } from './workspace-sqlite-inventory';
import { collectLegacyJournalInventory } from './workspace-legacy-journals';
import {
	collectLegacyFileInventory,
	collectOpfsOwnerInventory,
	collectWebStorageInventory,
	collectConsumerCredentialInventory,
	type OpfsOwnerEntry
} from './workspace-auxiliary-inventory';
import type { HubConnection } from './device-enrollment';
import type { WorkspaceMigrationSnapshot } from './workspace-migration';
type Options = {
	sqlite: SQLiteInventoryDriver;
	root: FileSystemDirectoryHandle;
	owners: readonly OpfsOwnerEntry[];
	journals: IDBFactory;
	/** Legacy page storage must be bridged as a frozen exact raw snapshot. Workers
	 * cannot read localStorage. This is preservation input, never trusted authority. */
	storage: Pick<Storage, 'length' | 'key' | 'getItem'>;
	readConnection(): Readonly<HubConnection> | null;
	assertLegacyRetired(): Promise<void>;
	signal?: AbortSignal;
};
function same(
	a: WorkspaceMigrationSnapshot['credential'],
	b: WorkspaceMigrationSnapshot['credential']
) {
	return (
		a.length === b.length &&
		a.every(
			(row, index) =>
				row.key === b[index].key &&
				row.value.length === b[index].value.length &&
				row.value.every((byte, i) => byte === b[index].value[i])
		)
	);
}
function wipe(part: Partial<WorkspaceMigrationSnapshot>) {
	for (const rows of Object.values(part)) if (rows) for (const row of rows) row.value.fill(0);
}
/** Worker/migration-owner collector only, not a migration entry point. The host
 * supplies the exclusive lease and real known-handle retirement. It must compare
 * fresh source-before/source-after and actual target snapshots with the runner;
 * sequential collection does not create an atomic transaction across stores.
 * No writes, outbox normalization, SQL export, provider calls or cleanup here.
 */
export async function collectWorkspaceSourceInventory(
	options: Options
): Promise<WorkspaceMigrationSnapshot> {
	const { root, journals, storage, readConnection, assertLegacyRetired, signal } = options;
	const owners = options.owners.map((entry) => ({ ...entry }));
	const all = options.sqlite.all.bind(options.sqlite);
	const transaction: SQLiteInventoryDriver['transaction'] = options.sqlite.transaction.bind(
		options.sqlite
	);
	const guard = () => signal?.throwIfAborted();
	const captured: Partial<WorkspaceMigrationSnapshot> = {};
	let returned = false;
	try {
		guard();
		await assertLegacyRetired();
		guard();
		await collectOpfsOwnerInventory(root, owners, signal);
		guard();
		Object.assign(captured, collectWebStorageInventory(storage));
		captured.credential = collectConsumerCredentialInventory(readConnection());
		Object.assign(
			captured,
			await collectSQLiteInventory({
				all: async (sql) => {
					guard();
					const value = await all(sql);
					guard();
					return value;
				},
				transaction
			})
		);
		guard();
		Object.assign(captured, await collectLegacyJournalInventory(journals, { signal }));
		guard();
		Object.assign(captured, await collectLegacyFileInventory(root, { signal }));
		guard();
		await collectOpfsOwnerInventory(root, owners, signal);
		guard();
		const afterStorage = collectWebStorageInventory(storage);
		try {
			const afterCredential = collectConsumerCredentialInventory(readConnection());
			try {
				if (
					!same(captured.recents!, afterStorage.recents) ||
					!same(captured.preferences!, afterStorage.preferences) ||
					!same(captured.credential, afterCredential)
				)
					throw new Error('Legacy metadata changed during inventory.');
			} finally {
				wipe({ credential: afterCredential });
			}
		} finally {
			wipe(afterStorage);
		}
		await assertLegacyRetired();
		guard();
		returned = true;
		return captured as WorkspaceMigrationSnapshot;
	} finally {
		if (!returned) wipe(captured);
	}
}
