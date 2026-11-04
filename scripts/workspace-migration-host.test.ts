import { expect, test } from 'bun:test';
const { createWorkerMigrationHost } = await import(
	process.env.IRIS_TEST_MIGRATION_HOST || '../apps/web/src/lib/workspace-migration-host'
);
import { runWorkspaceMigration } from '../apps/web/src/lib/workspace-migration-runner';
import { assertMigrationPreserved } from '../apps/web/src/lib/workspace-migration';
import { migrationHostFixture } from './migration-host-fixture';
test('one concrete host copies actual core SQLite, both pending journals, files and metadata before cleanup', async () => {
	const f = await migrationHostFixture(createWorkerMigrationHost);
	try {
		const before = await f.host.exclusive(async () => f.host.captureLegacy(await f.host.prepare()));
		const running = runWorkspaceMigration('synthetic-host', f.host);
		await expect(running).resolves.toMatchObject({ phase: 'complete' });
		const result = await running;
		expect(result.phase).toBe('complete');
		const actual = await f.host.exclusive(() => f.host.captureEncryptedTarget(result));
		assertMigrationPreserved(before, actual);
		expect(await f.host.exclusive(() => f.host.verifyLegacyAbsent(result))).toBe(true);
		expect(f.backups()).toBe(1);
		expect(actual['pending-intents'].length).toBeGreaterThan(0);
		expect(f.journalData.size).toBe(0);
		expect(f.storage.size).toBe(0);
	} finally {
		await f.close();
	}
});
test('copy failure remains copying and retries without losing dirty state or pending requests', async () => {
	const f = await migrationHostFixture(createWorkerMigrationHost);
	try {
		f.flags.failCopy = true;
		await expect(runWorkspaceMigration('synthetic-host', f.host)).rejects.toThrow();
		expect((await f.control.readManifest())?.phase).toBe('copying');
		expect(f.journalData.size).toBe(2);
		expect(f.root.entries.has('iris')).toBe(true);
		f.flags.failCopy = false;
		expect((await runWorkspaceMigration('synthetic-host', f.host)).phase).toBe('complete');
	} finally {
		await f.close();
	}
});
test('cleanup-phase lost acknowledgement and interrupted cleanup resume from authenticated target without recopy', async () => {
	for (const fault of ['lost-ack', 'partial-cleanup']) {
		const f = await migrationHostFixture(createWorkerMigrationHost);
		try {
			f.flags.lostAck = fault === 'lost-ack';
			f.flags.failRemove = fault === 'partial-cleanup';
			await expect(runWorkspaceMigration('synthetic-host', f.host)).rejects.toThrow();
			expect((await f.control.readManifest())?.phase).toBe('cleanup');
			const copied = f.backups();
			f.flags.lostAck = false;
			f.flags.failRemove = false;
			expect((await runWorkspaceMigration('synthetic-host', f.host)).phase).toBe('complete');
			expect(f.backups()).toBe(copied);
		} finally {
			await f.close();
		}
	}
});
test('missing engine encryption or changed internal pending values cannot publish or delete legacy stores', async () => {
	for (const fault of ['unencrypted', 'pending-changed']) {
		const f = await migrationHostFixture(createWorkerMigrationHost);
		try {
			f.flags.encrypted = fault !== 'unencrypted';
			f.flags.corruptPending = fault === 'pending-changed';
			await expect(runWorkspaceMigration('synthetic-host', f.host)).rejects.toThrow();
			expect((await f.control.readManifest())?.phase).toBe('copying');
			expect(f.root.entries.has('iris')).toBe(true);
			expect(f.journalData.size).toBe(2);
		} finally {
			await f.close();
		}
	}
});
test('unmapped pending journal scope and unknown physical namespace block cleanup without discarding raw values', async () => {
	for (const fault of ['scope', 'namespace']) {
		const f = await migrationHostFixture(createWorkerMigrationHost);
		try {
			if (fault === 'scope') f.journalData.get('iris-governance')![0].key = 'unmapped';
			else f.root.entries.set('unknown', { name: 'unknown', kind: 'file' });
			await expect(runWorkspaceMigration('synthetic-host', f.host)).rejects.toThrow();
			expect(f.journalData.size).toBe(2);
			expect(f.root.entries.has('iris')).toBe(true);
		} finally {
			await f.close();
		}
	}
});
test('published target corruption prevents resumed cleanup; completed host remains closed to plaintext bypass', async () => {
	const f = await migrationHostFixture(createWorkerMigrationHost);
	try {
		f.flags.lostAck = true;
		await expect(runWorkspaceMigration('synthetic-host', f.host)).rejects.toThrow();
		f.flags.lostAck = false;
		f.target().exec('DELETE FROM _core_pending');
		await expect(runWorkspaceMigration('synthetic-host', f.host)).rejects.toThrow();
		expect(f.root.entries.has('iris')).toBe(true);
		expect((await f.control.readManifest())?.phase).toBe('cleanup');
	} finally {
		await f.close();
	}
});
test('failed host initialization closes acquired cells even for undefined allocation failures', async () => {
	let opened = 0,
		closed = 0;
	await expect(
		migrationHostFixture(async (options) =>
			createWorkerMigrationHost({
				...options,
				openStore: async (...args) => {
					if (++opened === 2) throw undefined;
					const store = await options.openStore(...args);
					return {
						...store,
						close() {
							closed++;
							store.close();
						}
					};
				}
			})
		)
	).rejects.toThrow();
	expect(closed).toBe(1);
});
test('host close attempts every owned handle after primitive cleanup failure', async () => {
	let opened = 0,
		closed = 0;
	const f = await migrationHostFixture(async (options) =>
		createWorkerMigrationHost({
			...options,
			openStore: async (...args) => {
				opened++;
				const store = await options.openStore(...args);
				return {
					...store,
					close() {
						closed++;
						store.close();
						if (closed === 1) throw null;
					}
				};
			}
		})
	);
	try {
		expect(() => f.host.close()).toThrow();
		expect(closed).toBe(opened);
	} finally {
		await f.close();
	}
});
test('encrypted target names cannot overlap cleanup roots or be omitted', async () => {
	for (const targetFiles of [[], ['iris-attachments']])
		await expect(
			migrationHostFixture(async (options) =>
				createWorkerMigrationHost({
					...options,
					database: { ...options.database, targetFiles },
					source: {
						...options.source,
						owners: options.source.owners.filter((entry) => entry.name !== 'encrypted-1')
					}
				})
			).then(async (fixture) => {
				await fixture.close();
				return fixture;
			})
		).rejects.toThrow();
});
test('unpublished cleanup and active legacy handles cannot delete plaintext', async () => {
	const f = await migrationHostFixture(createWorkerMigrationHost);
	try {
		await f.host.exclusive(async () => {
			const planned = await f.host.prepare();
			await expect(f.host.cleanupLegacy({ ...planned, phase: 'cleanup' })).rejects.toThrow();
		});
		f.flags.retired = false;
		await expect(runWorkspaceMigration('synthetic-host', f.host)).rejects.toThrow();
		expect(f.root.entries.has('iris')).toBe(true);
		expect(f.journalData.size).toBe(2);
	} finally {
		await f.close();
	}
});
test('changed legacy metadata blocks resumed cleanup before deleting any other source store', async () => {
	const f = await migrationHostFixture(createWorkerMigrationHost);
	try {
		f.flags.lostAck = true;
		await expect(runWorkspaceMigration('synthetic-host', f.host)).rejects.toThrow();
		f.flags.lostAck = false;
		f.storage.set('unknown-preference', 'new unsynced value');
		await expect(runWorkspaceMigration('synthetic-host', f.host)).rejects.toThrow();
		expect(f.storage.get('unknown-preference')).toBe('new unsynced value');
		expect(f.root.entries.has('iris')).toBe(true);
		expect(f.journalData.size).toBe(2);
	} finally {
		await f.close();
	}
});
test('real engine-owner prototype methods retain their receiver when installed into the host', async () => {
	const f = await migrationHostFixture(async (options) => {
		const original = options.database;
		const engine = new (class {
			source = original.source;
			target = original.target;
			sourceFiles = original.sourceFiles;
			targetFiles = original.targetFiles;
			copies = 0;
			copyIntoTarget() {
				this.copies++;
				return original.copyIntoTarget();
			}
			assertTargetEncrypted() {
				if (this.copies < 0) throw Error('receiver lost');
				return original.assertTargetEncrypted();
			}
			closeSource() {
				return original.closeSource();
			}
		})();
		return createWorkerMigrationHost({ ...options, database: engine });
	});
	try {
		expect((await runWorkspaceMigration('synthetic-host', f.host)).phase).toBe('complete');
	} finally {
		await f.close();
	}
});

test('even a fully copied target cannot authorize cleanup while the authenticated manifest is copying', async () => {
	const f = await migrationHostFixture(createWorkerMigrationHost);
	try {
		await f.host.exclusive(async () => {
			const manifest = await f.host.prepare();
			await f.host.writeManifest(null, manifest);
			await f.host.copyToEncryptedTarget(manifest);
			await expect(f.host.cleanupLegacy(manifest)).rejects.toThrow();
			expect(f.root.entries.has('iris')).toBe(true);
			expect(f.journalData.size).toBe(2);
		});
	} finally {
		await f.close();
	}
});
