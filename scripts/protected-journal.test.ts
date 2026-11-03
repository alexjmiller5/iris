import { createWorkspaceAdmission } from '../apps/web/src/lib/workspace-admission';
import { expect, test } from 'bun:test';
const { createJournalProtection, openProtectedJournal } = (await import(
	process.env.IRIS_TEST_PROTECTED_JOURNAL || '../apps/web/src/lib/governance/protected-journal'
)) as typeof import('../apps/web/src/lib/governance/protected-journal');
import type { EncryptedWorkspaceRecord } from '../apps/web/src/lib/workspace-records';
const root = new Uint8Array(32).fill(19);
const scope = JSON.stringify(['synthetic-endpoint', 'deployment-1', 'session-1', 'principal-1']);
const entry = {
	id: 'pending-1',
	idempotencyKey: 'opaque-idempotency',
	value: '9223372036854775807'
};
const codec = {
	encode: (value: typeof entry) => JSON.stringify(value),
	decode: (raw: unknown) => {
		if (typeof raw !== 'string') throw Error('Unreadable');
		return JSON.parse(raw) as typeof entry;
	}
};
function fixture() {
	let retained: EncryptedWorkspaceRecord | null = null;
	let closed = false;
	const controller = new AbortController();
	let key = '';
	const store = {
		load: async () => structuredClone(retained),
		retain: async (value: EncryptedWorkspaceRecord) => {
			if (retained) {
				if (JSON.stringify(retained) === JSON.stringify(value)) return;
				throw Error('Concurrent pending entry');
			}
			retained = structuredClone(value);
		},
		resolve: async (value: EncryptedWorkspaceRecord) => {
			if (JSON.stringify(retained) !== JSON.stringify(value)) throw Error('Changed');
			retained = null;
		},
		close: () => {
			closed = true;
		}
	};
	return {
		store,
		controller,
		get retained() {
			return retained;
		},
		get closed() {
			return closed;
		},
		get key() {
			return key;
		},
		openStore: async (k: string) => {
			key = k;
			return store;
		},
		admission: {
			run: async <T,>(work: (resource: unknown, signal: AbortSignal) => Promise<T>) => {
				controller.signal.throwIfAborted();
				const value = await work({}, controller.signal);
				controller.signal.throwIfAborted();
				return value;
			}
		}
	};
}
test('scope keys are opaque, stable and separated by workspace and journal kind', async () => {
	const a = await createJournalProtection(root, 'workspace-1', 1, 'governance', scope);
	const b = await createJournalProtection(root, 'workspace-1', 1, 'governance', scope);
	const c = await createJournalProtection(root, 'workspace-1', 1, 'changesets', scope);
	expect(a.key).toMatch(/^[a-f0-9]{64}$/);
	expect(a.key).toBe(b.key);
	expect(a.key).not.toBe(c.key);
	expect(a.key).not.toBe(
		(await createJournalProtection(root, 'workspace-2', 1, 'governance', scope)).key
	);
});
test('retained storage contains only ciphertext while exact pending bytes survive reopen', async () => {
	const f = fixture(),
		protection = await createJournalProtection(root, 'workspace-1', 1, 'governance', scope);
	const journal = await openProtectedJournal(codec, { ...f, protection });
	await journal.retain(entry);
	expect(JSON.stringify(f.retained)).not.toContain(entry.value);
	expect(JSON.stringify(f.retained)).not.toContain(entry.idempotencyKey);
	expect(f.key).toBe(protection.key);
	expect(await journal.load()).toEqual(entry);
	const reopened = await openProtectedJournal(codec, { ...f, protection });
	expect(await reopened.load()).toEqual(entry);
	await reopened.retain(entry);
	await reopened.resolve(entry);
	expect(f.retained).toBeNull();
});
test('uncertain pending entry cannot be overwritten or resolved with a different request', async () => {
	const f = fixture(),
		protection = await createJournalProtection(root, 'workspace-1', 1, 'changesets', scope);
	const journal = await openProtectedJournal(codec, { ...f, protection });
	await journal.retain(entry);
	const before = structuredClone(f.retained);
	await expect(journal.retain({ ...entry, idempotencyKey: 'different' })).rejects.toThrow();
	await expect(journal.resolve({ ...entry, idempotencyKey: 'different' })).rejects.toThrow();
	expect(f.retained).toEqual(before);
});
test('scope or generation replay is rejected instead of becoming an empty journal', async () => {
	const f = fixture(),
		a = await createJournalProtection(root, 'workspace-1', 1, 'governance', scope);
	const first = await openProtectedJournal(codec, { ...f, protection: a });
	await first.retain(entry);
	for (const p of [
		await createJournalProtection(root, 'workspace-1', 2, 'governance', scope),
		await createJournalProtection(root, 'workspace-1', 1, 'governance', 'other-scope')
	]) {
		const other = await openProtectedJournal(codec, { ...f, protection: p });
		await expect(other.load()).rejects.toThrow();
	}
});
test('lock during encryption cannot persist or acknowledge a new pending entry', async () => {
	const f = fixture(),
		original = await createJournalProtection(root, 'workspace-1', 1, 'governance', scope);
	const protection = {
		...original,
		seal: async (value: Uint8Array) => {
			const sealed = await original.seal(value);
			f.controller.abort();
			return sealed;
		}
	};
	const journal = await openProtectedJournal(codec, { ...f, protection });
	await expect(journal.retain(entry)).rejects.toThrow();
	expect(f.retained).toBeNull();
});
test('close denies stale calls and closes the persistence handle', async () => {
	const f = fixture(),
		protection = await createJournalProtection(root, 'workspace-1', 1, 'governance', scope);
	const journal = await openProtectedJournal(codec, { ...f, protection });
	journal.close();
	expect(f.closed).toBe(true);
	await expect(journal.load()).rejects.toThrow();
});

test('idempotent retain rechecks the ciphertext snapshot after decryption', async () => {
	const f = fixture(),
		original = await createJournalProtection(root, 'workspace-1', 1, 'governance', scope);
	const first = await openProtectedJournal(codec, { ...f, protection: original });
	await first.retain(entry);
	const replacement = await original.seal(
		new TextEncoder().encode(JSON.stringify({ ...entry, id: 'replacement' }))
	);
	const protection = {
		...original,
		open: async (value: unknown) => {
			const bytes = await original.open(value);
			await f.store.resolve(f.retained!);
			await f.store.retain(replacement);
			return bytes;
		}
	};
	const journal = await openProtectedJournal(codec, { ...f, protection });
	await expect(journal.retain(entry)).rejects.toThrow();
	expect(f.retained).toEqual(replacement);
});
test('resolve cannot delete a concurrently replaced ciphertext', async () => {
	const f = fixture(),
		original = await createJournalProtection(root, 'workspace-1', 1, 'governance', scope);
	const first = await openProtectedJournal(codec, { ...f, protection: original });
	await first.retain(entry);
	const replacement = await original.seal(
		new TextEncoder().encode(JSON.stringify({ ...entry, id: 'replacement' }))
	);
	const protection = {
		...original,
		open: async (value: unknown) => {
			const bytes = await original.open(value);
			await f.store.resolve(f.retained!);
			await f.store.retain(replacement);
			return bytes;
		}
	};
	const journal = await openProtectedJournal(codec, { ...f, protection });
	await expect(journal.resolve(entry)).rejects.toThrow();
	expect(f.retained).toEqual(replacement);
});
test('ciphertext corruption never becomes empty or replaces an uncertain intent', async () => {
	const f = fixture(),
		protection = await createJournalProtection(root, 'workspace-1', 1, 'governance', scope);
	const sealed = await protection.seal(new TextEncoder().encode(JSON.stringify(entry)));
	sealed.ciphertext[0] ^= 1;
	await f.store.retain(sealed);
	const journal = await openProtectedJournal(codec, { ...f, protection });
	await expect(journal.load()).rejects.toThrow();
	await expect(journal.retain(entry)).rejects.toThrow();
	expect(f.retained).toEqual(sealed);
});
test('revoked admission during opening closes the newly acquired handle', async () => {
	const f = fixture(),
		protection = await createJournalProtection(root, 'workspace-1', 1, 'governance', scope);
	await expect(
		openProtectedJournal(codec, {
			...f,
			protection,
			openStore: async () => {
				f.controller.abort();
				return f.store;
			}
		})
	).rejects.toThrow();
	expect(f.closed).toBe(true);
});

test('strict storage codec survives structured clone, rejects plaintext and compares exact ciphertext', async () => {
	const f = fixture(),
		protection = await createJournalProtection(root, 'workspace-1', 1, 'governance', scope);
	await openProtectedJournal(codec, {
		...f,
		protection,
		openStore: async (key, sealedCodec, options) => {
			expect(key).toBe(protection.key);
			expect(options.databaseName).toBe(protection.databaseName);
			const sealed = await protection.seal(new TextEncoder().encode(JSON.stringify(entry)));
			const encoded = sealedCodec.encode(sealed);
			const clone = structuredClone(encoded);
			expect(sealedCodec.equal(encoded, clone)).toBe(true);
			expect(sealedCodec.decode(clone)).toEqual(sealed);
			const changed = structuredClone(sealed);
			changed.ciphertext[0] ^= 1;
			expect(sealedCodec.equal(encoded, changed)).toBe(false);
			for (const raw of [
				JSON.stringify(entry),
				entry,
				{ ...sealed, version: 2 },
				{ ...sealed, iv: new Uint8Array(11) }
			])
				expect(() => sealedCodec.decode(raw)).toThrow();
			sealed.iv[0] ^= 1;
			expect(sealedCodec.equal(encoded, sealed)).toBe(false);
			return f.store;
		}
	});
});

test('actual workspace admission supplies its abort signal while enforcing durable peer revocation', async () => {
	const f = fixture();
	let revision = 0;
	const admission = createWorkspaceAdmission({
		revisions: {
			read: async () => revision,
			advance: async () => ++revision,
			subscribe: () => () => {}
		},
		close: async () => {
			f.store.close();
		}
	});
	await admission.unlock(async () => ({ worker: 'synthetic-vault' }));
	const protection = await createJournalProtection(root, 'workspace-1', 1, 'governance', scope);
	const journal = await openProtectedJournal(codec, { ...f, admission, protection });
	await journal.retain(entry);
	expect(await journal.load()).toEqual(entry);
	revision++;
	await expect(journal.load()).rejects.toThrow();
	expect(f.closed).toBe(true);
	expect(f.retained).not.toBeNull();
	await admission.close();
});
