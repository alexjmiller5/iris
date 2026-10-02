import { afterEach, expect, test, vi } from 'vitest';
import { CORE_CONTRACT_HASH } from '../../../../packages/core/contract.generated';
import { WorkspaceDatabase } from './database';

class FakeWorker {
	static current: FakeWorker;
	onmessage?: (event: { data: unknown }) => void;
	onerror?: (event: unknown) => void;
	onmessageerror?: () => void;
	messages: Record<string, unknown>[] = [];
	terminate = vi.fn();
	constructor() {
		FakeWorker.current = this;
	}
	postMessage(message: Record<string, unknown>) {
		this.messages.push(message);
	}
	reply(data: Record<string, unknown>) {
		this.onmessage?.({ data: { contractHash: CORE_CONTRACT_HASH, ...data } });
	}
}
vi.stubGlobal('Worker', FakeWorker);
afterEach(() => vi.clearAllMocks());

test('requests carry the generated contract identity and resolve the corresponding result', async () => {
	const db = new WorkspaceDatabase();
	const result = db.request('rows', { view: { table: 'items', limit: 2 } });
	const worker = FakeWorker.current;
	expect(worker.messages[0]).toEqual({
		id: 1,
		method: 'rows',
		args: { view: { table: 'items', limit: 2 } },
		contractHash: CORE_CONTRACT_HASH
	});
	worker.reply({ id: 1, result: [{ id: 'item1' }] });
	expect(await result).toEqual([{ id: 'item1' }]);
	db.close();
	worker.reply({ id: 2, result: null });
});

test('a stale worker is stopped before any response or change event is accepted', async () => {
	const db = new WorkspaceDatabase();
	const changes = vi.fn();
	db.addEventListener('change', changes);
	const result = db.request('snapshot');
	const worker = FakeWorker.current;
	worker.reply({ changed: true, contractHash: 'stale' });
	await expect(result).rejects.toThrow('contract');
	expect(changes).not.toHaveBeenCalled();
	expect(worker.terminate).toHaveBeenCalledOnce();
	await expect(db.request('snapshot')).rejects.toThrow('closed');
});
