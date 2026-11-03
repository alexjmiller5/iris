import { assertMigrationPreserved, type WorkspaceMigrationSnapshot } from './workspace-migration';
export interface WorkspaceMigrationManifest {
	version: 1;
	workspace: string;
	source: string;
	target: string;
	phase: 'copying' | 'cleanup' | 'complete';
}
export interface WorkspaceMigrationHost {
	/** Exclusive workspace lease; ordinary data admission stays closed. */
	exclusive<T>(work: () => Promise<T>): Promise<T>;
	/** Authenticate/decrypt the manifest before returning it. */
	readManifest(): Promise<WorkspaceMigrationManifest | null>;
	/** Includes explicit restart/closure precondition and known-handle retirement. */
	assertLegacyRetired(): Promise<void>;
	prepare(): Promise<WorkspaceMigrationManifest>;
	/** Strict durable compare-and-swap; never acknowledge a pending write early. */
	writeManifest(
		before: WorkspaceMigrationManifest | null,
		next: WorkspaceMigrationManifest
	): Promise<void>;
	captureLegacy(manifest: WorkspaceMigrationManifest): Promise<WorkspaceMigrationSnapshot>;
	/** Idempotent staging; resolve only after every encrypted store is durable. */
	copyToEncryptedTarget(manifest: WorkspaceMigrationManifest): Promise<void>;
	captureEncryptedTarget(manifest: WorkspaceMigrationManifest): Promise<WorkspaceMigrationSnapshot>;
	cleanupLegacy(manifest: WorkspaceMigrationManifest): Promise<void>;
	verifyLegacyAbsent(manifest: WorkspaceMigrationManifest): Promise<boolean>;
}
function checked(value: WorkspaceMigrationManifest, workspace: string) {
	if (
		!value ||
		typeof value !== 'object' ||
		Array.isArray(value) ||
		Object.keys(value).length !== 5 ||
		!['version', 'workspace', 'source', 'target', 'phase'].every((key) =>
			Object.hasOwn(value, key)
		) ||
		value.version !== 1 ||
		value.workspace !== workspace ||
		!workspace ||
		typeof value.source !== 'string' ||
		!value.source ||
		typeof value.target !== 'string' ||
		!value.target ||
		value.source === value.target ||
		!['copying', 'cleanup', 'complete'].includes(value.phase)
	)
		throw new Error('Invalid workspace migration manifest.');
	return value;
}
/** Never selects the plaintext source as an ordinary workspace fallback. */
export function activeEncryptedGeneration(
	manifest: WorkspaceMigrationManifest,
	workspace: string
): string | null {
	const value = checked(manifest, workspace);
	return value.phase === 'copying' ? null : value.target;
}
/** Sequencing only. Storage adapters must supply real authenticated manifests,
 * durable OPFS/strict IDB receipts and complete logical snapshots. This does not
 * assert a transaction across stores, secure erasure, or control of legacy code.
 * Cleanup errors retain a published encrypted target and an incomplete manifest.
 */
export async function runWorkspaceMigration(
	workspace: string,
	host: WorkspaceMigrationHost
): Promise<WorkspaceMigrationManifest> {
	return host.exclusive(async () => {
		async function persist(
			before: WorkspaceMigrationManifest | null,
			next: WorkspaceMigrationManifest
		) {
			await host.writeManifest(before, next);
			const observed = await host.readManifest();
			if (!observed) throw new Error('Migration manifest write was not observed.');
			checked(observed, workspace);
			for (const field of ['version', 'workspace', 'source', 'target', 'phase'] as const)
				if (observed[field] !== next[field])
					throw new Error('Migration manifest write was not observed.');
			return observed;
		}
		let manifest = await host.readManifest();
		if (manifest) {
			checked(manifest, workspace);
			if (manifest.phase === 'complete') return manifest;
		}
		await host.assertLegacyRetired();
		if (!manifest) {
			const planned = checked(await host.prepare(), workspace);
			if (planned.phase !== 'copying')
				throw new Error('Migration must start with encrypted staging.');
			manifest = await persist(null, planned);
		}
		if (manifest.phase === 'copying') {
			const before = await host.captureLegacy(manifest);
			await host.copyToEncryptedTarget(manifest);
			assertMigrationPreserved(before, await host.captureLegacy(manifest));
			assertMigrationPreserved(before, await host.captureEncryptedTarget(manifest));
			const published: WorkspaceMigrationManifest = { ...manifest, phase: 'cleanup' };
			manifest = await persist(manifest, published);
		}
		// Once published, resume only cleanup: the old source may already be partial.
		await host.cleanupLegacy(manifest);
		if (!(await host.verifyLegacyAbsent(manifest)))
			throw new Error('Plaintext cleanup is incomplete.');
		const complete: WorkspaceMigrationManifest = { ...manifest, phase: 'complete' };
		return persist(manifest, complete);
	});
}
