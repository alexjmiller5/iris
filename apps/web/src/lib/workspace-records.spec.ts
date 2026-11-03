import { expect, test, vi } from 'vitest';
import { createWorkspaceRecords } from './workspace-records';

const root = new Uint8Array(32).fill(17);
const context = { store: 'synthetic-store', id: 'opaque-record', generation: 1 };

test('binary records roundtrip after structured clone without altering caller bytes', async () => {
	const records = await createWorkspaceRecords(root, 'workspace-1', 'metadata');
	const input = new Uint8Array([0, 255, 128, 1, 2]);
	const sealed = await records.seal(context, input);
	expect(await records.open(context, structuredClone(sealed))).toEqual(input);
	expect(input).toEqual(new Uint8Array([0, 255, 128, 1, 2]));
	expect(root).toEqual(new Uint8Array(32).fill(17));
	expect(sealed.ciphertext).not.toEqual(input);
});
test('empty records remain authenticated and each sealing has a fresh nonce', async () => {
	const records = await createWorkspaceRecords(root, 'workspace-1', 'files');
	const a = await records.seal(context, new Uint8Array());
	const b = await records.seal(context, new Uint8Array());
	expect(a.iv).not.toEqual(b.iv);
	expect(a.ciphertext).toHaveLength(16);
	expect(await records.open(context, a)).toHaveLength(0);
});
test('workspace, purpose, store, record and generation substitutions refuse', async () => {
	const records = await createWorkspaceRecords(root, 'workspace-1', 'metadata');
	const sealed = await records.seal(context, new TextEncoder().encode('synthetic pending intent'));
	for (const changed of [
		{ ...context, store: 'other' },
		{ ...context, id: 'other' },
		{ ...context, generation: 2 }
	]) {
		await expect(records.open(changed, sealed)).rejects.toThrow();
	}
	const foreign = await createWorkspaceRecords(root, 'workspace-2', 'metadata');
	await expect(foreign.open(context, sealed)).rejects.toThrow();
	const files = await createWorkspaceRecords(root, 'workspace-1', 'files');
	await expect(files.open(context, sealed)).rejects.toThrow();
});
test('ciphertext, authentication tag and nonce mutations refuse without mutating stored bytes', async () => {
	const records = await createWorkspaceRecords(root, 'workspace-1', 'metadata');
	const sealed = await records.seal(context, new Uint8Array([1, 2, 3]));
	for (const field of ['iv', 'ciphertext'] as const) {
		const changed = structuredClone(sealed);
		changed[field][0] ^= 1;
		await expect(records.open(context, changed)).rejects.toThrow();
	}
	const changed = structuredClone(sealed);
	changed.ciphertext[changed.ciphertext.length - 1] ^= 1;
	await expect(records.open(context, changed)).rejects.toThrow();
	expect(await records.open(context, sealed)).toEqual(new Uint8Array([1, 2, 3]));
});
test('malformed public records and context fail before decryption', async () => {
	const records = await createWorkspaceRecords(root, 'workspace-1', 'metadata');
	const sealed = await records.seal(context, new Uint8Array([1]));
	const decrypt = vi.spyOn(crypto.subtle, 'decrypt');
	try {
		for (const change of [
			{ version: 2 },
			{ iv: new Uint8Array(11) },
			{ ciphertext: new Uint8Array(15) },
			{ ciphertext: 'untrusted' },
			{ unexpected: true }
		])
			await expect(records.open(context, { ...sealed, ...change })).rejects.toThrow();
		for (const changed of [
			{ ...context, generation: -1 },
			{ ...context, generation: NaN },
			{ ...context, id: '' }
		])
			await expect(records.open(changed, sealed)).rejects.toThrow();
		expect(decrypt).not.toHaveBeenCalled();
	} finally {
		decrypt.mockRestore();
	}
});
test('bounded record size refuses oversized input before encryption allocation', async () => {
	const records = await createWorkspaceRecords(root, 'workspace-1', 'files');
	const encrypt = vi.spyOn(crypto.subtle, 'encrypt').mockResolvedValue(new ArrayBuffer(16));
	try {
		await expect(records.seal(context, new Uint8Array(16 * 1024 * 1024 + 1))).rejects.toThrow();
		expect(encrypt).not.toHaveBeenCalled();
	} finally {
		encrypt.mockRestore();
	}
});
