import { expect, test } from 'bun:test';
import {
	runWorkspaceMigration,
	activeEncryptedGeneration,
	type WorkspaceMigrationManifest
} from '../apps/web/src/lib/workspace-migration-runner';
import type { WorkspaceMigrationSnapshot } from '../apps/web/src/lib/workspace-migration';
function fixture() {
	const snapshot: WorkspaceMigrationSnapshot = {
		'database-schema': [],
		'database-values': [{ key: 'row', value: new Uint8Array([1]) }],
		'pending-intents': [{ key: 'pending', value: new Uint8Array([2]) }],
		'governance-journal': [],
		'changeset-journal': [],
		files: [],
		recents: [],
		preferences: [],
		credential: [],
		backups: []
	};
	const state = {
		manifest: null as WorkspaceMigrationManifest | null,
		source: structuredClone(snapshot),
		target: structuredClone(snapshot),
		events: [] as string[],
		retired: true,
		failCleanup: false,
		absent: true,
		commitThenThrow: false
	};
	const host = {
		exclusive: async <T,>(work: () => Promise<T>) => work(),
		readManifest: async () => state.manifest,
		assertLegacyRetired: async () => {
			state.events.push('retire');
			if (!state.retired) throw Error('Close legacy tabs');
		},
		prepare: async () => ({
			version: 1 as const,
			workspace: 'workspace-1',
			source: 'legacy-1',
			target: 'encrypted-2',
			phase: 'copying' as const
		}),
		writeManifest: async (
			_before: WorkspaceMigrationManifest | null,
			next: WorkspaceMigrationManifest
		) => {
			state.events.push(next.phase);
			state.manifest = structuredClone(next);
			if (next.phase === 'cleanup' && state.commitThenThrow)
				throw Error('Commit acknowledgment lost');
		},
		captureLegacy: async () => {
			state.events.push('source');
			return structuredClone(state.source);
		},
		copyToEncryptedTarget: async () => {
			state.events.push('copy');
		},
		captureEncryptedTarget: async () => {
			state.events.push('target');
			return structuredClone(state.target);
		},
		cleanupLegacy: async () => {
			state.events.push('delete-old');
			if (state.failCleanup) throw Error('Cleanup interrupted');
		},
		verifyLegacyAbsent: async () => {
			state.events.push('verify-absent');
			return state.absent;
		}
	};
	return { state, host };
}
test('publish only after preserved values; declare complete only after plaintext absence verification', async () => {
	const { state, host } = fixture();
	const result = await runWorkspaceMigration('workspace-1', host);
	expect(result.phase).toBe('complete');
	expect(activeEncryptedGeneration(result, 'workspace-1')).toBe('encrypted-2');
	expect(state.events).toEqual([
		'retire',
		'copying',
		'source',
		'copy',
		'source',
		'target',
		'cleanup',
		'delete-old',
		'verify-absent',
		'complete'
	]);
});
test('equal counts with altered target pending intent block publication and cleanup', async () => {
	const { state, host } = fixture();
	state.target['pending-intents'][0].value[0] = 3;
	await expect(runWorkspaceMigration('workspace-1', host)).rejects.toThrow();
	expect(state.manifest?.phase).toBe('copying');
	expect(state.events).not.toContain('delete-old');
	expect(activeEncryptedGeneration(state.manifest!, 'workspace-1')).toBeNull();
});
test('changed legacy values during copy block publication and preserve the newer source', async () => {
	const { state, host } = fixture();
	host.copyToEncryptedTarget = async () => {
		state.source['database-values'][0].value[0] = 7;
	};
	await expect(runWorkspaceMigration('workspace-1', host)).rejects.toThrow();
	expect(state.manifest?.phase).toBe('copying');
	expect(state.source['database-values'][0].value[0]).toBe(7);
	expect(state.events).not.toContain('delete-old');
});
test('unknown publication acknowledgment never starts deletion; resume trusts durable phase', async () => {
	const { state, host } = fixture();
	state.commitThenThrow = true;
	await expect(runWorkspaceMigration('workspace-1', host)).rejects.toThrow(
		'Commit acknowledgment lost'
	);
	expect(state.manifest?.phase).toBe('cleanup');
	expect(state.events).not.toContain('delete-old');
	state.commitThenThrow = false;
	state.events = [];
	expect((await runWorkspaceMigration('workspace-1', host)).phase).toBe('complete');
	expect(state.events).not.toContain('copy');
	expect(state.events).not.toContain('source');
});
test('partial cleanup remains visibly incomplete and resumes without copying from partial plaintext', async () => {
	const { state, host } = fixture();
	state.failCleanup = true;
	await expect(runWorkspaceMigration('workspace-1', host)).rejects.toThrow('Cleanup interrupted');
	expect(state.manifest?.phase).toBe('cleanup');
	state.source['database-values'] = [];
	state.failCleanup = false;
	state.events = [];
	expect((await runWorkspaceMigration('workspace-1', host)).phase).toBe('complete');
	expect(state.events).not.toContain('copy');
	expect(state.events).not.toContain('source');
	expect(state.target['pending-intents'][0].value[0]).toBe(2);
});
test('unverified plaintext absence never yields protected completion', async () => {
	const { state, host } = fixture();
	state.absent = false;
	await expect(runWorkspaceMigration('workspace-1', host)).rejects.toThrow();
	expect(state.manifest?.phase).toBe('cleanup');
});
test('legacy closure precondition fails before migration state or source access', async () => {
	const { state, host } = fixture();
	state.retired = false;
	await expect(runWorkspaceMigration('workspace-1', host)).rejects.toThrow('Close legacy tabs');
	expect(state.manifest).toBeNull();
	expect(state.events).toEqual(['retire']);
});
test('unsupported or wrong-workspace manifests never select a plaintext fallback', async () => {
	const { state, host } = fixture();
	state.manifest = {
		version: 1,
		workspace: 'foreign',
		source: 'a',
		target: 'b',
		phase: 'complete'
	};
	await expect(runWorkspaceMigration('workspace-1', host)).rejects.toThrow();
	expect(state.events).toEqual([]);
});
test.each(['copying', 'cleanup', 'complete'] as const)(
	'a no-op %s manifest write cannot acknowledge migration progress',
	async (phase) => {
		const { state, host } = fixture(),
			write = host.writeManifest;
		host.writeManifest = async (before, next) => {
			if (next.phase !== phase) await write(before, next);
		};
		await expect(runWorkspaceMigration('workspace-1', host)).rejects.toThrow();
		expect(state.manifest?.phase ?? null).toBe(
			phase === 'copying' ? null : phase === 'cleanup' ? 'copying' : 'cleanup'
		);
		if (phase !== 'complete') expect(state.events).not.toContain('delete-old');
	}
);
