import { expect, test, vi } from 'vitest';
import {
	createWorkspaceKey,
	unlockWorkspaceKey,
	rewrapWorkspaceKey,
	deriveWorkspaceKey
} from './workspace-keys';
const workspace = 'opaque-workspace';
const passphrase = 'synthetic long test passphrase';

test('cold JSON reopen restores only the wrapped random key', async () => {
	const created = await createWorkspaceKey(workspace, passphrase);
	const stored = JSON.parse(JSON.stringify(created.envelope));
	const key = await unlockWorkspaceKey(stored, workspace, passphrase);
	expect(key).toEqual(created.key);
	expect(key).toHaveLength(32);
	expect(JSON.stringify(stored)).not.toContain(passphrase);
	expect(stored).not.toHaveProperty('key');
});
test('wrong secret and workspace replay refuse without changing the envelope', async () => {
	const { envelope } = await createWorkspaceKey(workspace, passphrase);
	const before = JSON.stringify(envelope);
	await expect(unlockWorkspaceKey(envelope, workspace, 'incorrect secret')).rejects.toThrow(
		'Cannot unlock'
	);
	await expect(unlockWorkspaceKey(envelope, 'another-workspace', passphrase)).rejects.toThrow();
	await expect(
		unlockWorkspaceKey(
			{ ...envelope, workspace: 'another-workspace' },
			'another-workspace',
			passphrase
		)
	).rejects.toThrow('Cannot unlock');
	expect(JSON.stringify(envelope)).toBe(before);
});
test('fresh wrapping uses independent random salt and nonce', async () => {
	const a = await createWorkspaceKey(workspace, passphrase),
		b = await createWorkspaceKey(workspace, passphrase);
	expect(a.key).not.toEqual(b.key);
	expect(a.envelope.salt).not.toBe(b.envelope.salt);
	expect(a.envelope.iv).not.toBe(b.envelope.iv);
});
test('authenticated envelope refuses ciphertext and KDF-parameter substitution', async () => {
	const { envelope } = await createWorkspaceKey(workspace, passphrase);
	const bytes = Uint8Array.from(atob(envelope.wrappedKey), (c) => c.charCodeAt(0));
	bytes[0] ^= 1;
	await expect(
		unlockWorkspaceKey(
			{ ...envelope, wrappedKey: btoa(String.fromCharCode(...bytes)) },
			workspace,
			passphrase
		)
	).rejects.toThrow('Cannot unlock');
	await expect(
		unlockWorkspaceKey({ ...envelope, iterations: envelope.iterations + 1 }, workspace, passphrase)
	).rejects.toThrow('Cannot unlock');
});
test.each([0, -1, 1.5, Number.MAX_SAFE_INTEGER, Infinity, NaN])(
	'invalid KDF cost %s is rejected before derivation',
	async (iterations) => {
		const { envelope } = await createWorkspaceKey(workspace, passphrase);
		await expect(
			unlockWorkspaceKey({ ...envelope, iterations }, workspace, passphrase)
		).rejects.toThrow('Invalid encrypted workspace');
	}
);
test('domain-separated keys differ by purpose and workspace', async () => {
	const { key } = await createWorkspaceKey(workspace, passphrase);
	const database = await deriveWorkspaceKey(key, workspace, 'database');
	expect(database).toHaveLength(32);
	expect(await deriveWorkspaceKey(key, workspace, 'database')).toEqual(database);
	expect(await deriveWorkspaceKey(key, workspace, 'files')).not.toEqual(database);
	expect(await deriveWorkspaceKey(key, 'another-workspace', 'database')).not.toEqual(database);
});
test('rewrap preserves root key and does not revoke an older copied envelope', async () => {
	const { envelope, key } = await createWorkspaceKey(workspace, passphrase);
	const copied = JSON.parse(JSON.stringify(envelope));
	const next = await rewrapWorkspaceKey(
		envelope,
		workspace,
		passphrase,
		'replacement synthetic passphrase'
	);
	expect(await unlockWorkspaceKey(next, workspace, 'replacement synthetic passphrase')).toEqual(
		key
	);
	await expect(unlockWorkspaceKey(next, workspace, passphrase)).rejects.toThrow('Cannot unlock');
	expect(await unlockWorkspaceKey(copied, workspace, passphrase)).toEqual(key);
});

test('malformed public envelopes reject before password import or KDF allocation', async () => {
	const { envelope } = await createWorkspaceKey(workspace, passphrase);
	const imported = vi.spyOn(crypto.subtle, 'importKey');
	const derived = vi.spyOn(crypto.subtle, 'deriveKey');
	try {
		for (const change of [
			{ version: 2 },
			{ kdf: 'untrusted' },
			{ cipher: 'AES-CBC' },
			{ iterations: 2_000_001 },
			{ salt: 'a'.repeat(1_000_000) },
			{ iv: '' },
			{ wrappedKey: 'AAAA' },
			{ extra: true }
		]) {
			await expect(
				unlockWorkspaceKey({ ...envelope, ...change }, workspace, passphrase)
			).rejects.toThrow('Invalid encrypted workspace');
		}
		expect(imported).not.toHaveBeenCalled();
		expect(derived).not.toHaveBeenCalled();
	} finally {
		imported.mockRestore();
		derived.mockRestore();
	}
});
