import { expect, test } from 'vitest';
import { createWorkspaceAdmission, type WorkspaceRevisions } from './workspace-admission';
const deferred = <T>() => {
	let resolve!: (v: T) => void;
	const promise = new Promise<T>((r) => (resolve = r));
	return { promise, resolve };
};
function revisions() {
	let value = 0;
	const listeners = new Set<() => void>();
	return {
		read: async () => value,
		advance: async () => {
			value++;
			for (const l of listeners) l();
			return value;
		},
		subscribe: (f: () => void) => {
			listeners.add(f);
			return () => listeners.delete(f);
		}
	};
}
function fixture(store: WorkspaceRevisions = revisions()) {
	const closed: number[] = [];
	let next = 0;
	const gate = createWorkspaceAdmission({
		revisions: store,
		close: async (resource: { id: number }) => {
			closed.push(resource.id);
		}
	});
	return { gate, closed, open: () => gate.unlock(async () => ({ id: ++next })) };
}
test('cold state denies operations before invoking their body', async () => {
	const { gate } = fixture();
	let called = false;
	await expect(
		gate.run(async () => {
			called = true;
		})
	).rejects.toThrow('locked');
	expect(called).toBe(false);
});
test('unlock admits operations and a peer lock revokes both tabs', async () => {
	const shared = revisions(),
		a = fixture(shared),
		b = fixture(shared);
	await a.open();
	await b.open();
	expect(await a.gate.run(async (r) => r.id)).toBe(1);
	await a.gate.lock();
	await expect(a.gate.run(async () => 1)).rejects.toThrow('locked');
	await expect(b.gate.run(async () => 1)).rejects.toThrow('locked');
	expect(a.closed).toEqual([1]);
	expect(b.closed).toEqual([1]);
});
test('lock rejects a late read result even if transport ignores abort', async () => {
	const { gate, open } = fixture();
	await open();
	const held = deferred<string>();
	let started = deferred<void>();
	const result = gate.run(async (_r, signal) => {
		expect(signal.aborted).toBe(false);
		started.resolve();
		return held.promise;
	});
	await started.promise;
	const rejected = expect(result).rejects.toThrow('locked');
	await gate.lock();
	held.resolve('private result');
	await rejected;
});
test('locking during unlock disposes a late opened resource instead of admitting it', async () => {
	const { gate, closed } = fixture();
	const pending = deferred<{ id: number }>();
	const started = deferred<void>();
	const unlocked = gate.unlock(() => {
		started.resolve();
		return pending.promise;
	});
	await started.promise;
	const rejected = expect(unlocked).rejects.toThrow('locked');
	const locked = gate.lock();
	pending.resolve({ id: 42 });
	await rejected;
	await locked;
	expect(closed).toEqual([42]);
	await expect(gate.run(async () => 1)).rejects.toThrow('locked');
});
test('a lost peer notification cannot bypass the durable generation check', async () => {
	let revision = 0;
	const store = {
		read: async () => revision,
		advance: async () => ++revision,
		subscribe: () => () => {}
	};
	const { gate, open, closed } = fixture(store);
	await open();
	revision++;
	let called = false;
	await expect(
		gate.run(async () => {
			called = true;
		})
	).rejects.toThrow('locked');
	expect(called).toBe(false);
	expect(closed).toEqual([1]);
});
test('cleanup failure leaves admission closed and allows explicit retry', async () => {
	let fail = true;
	const store = revisions();
	let attempts = 0;
	const gate = createWorkspaceAdmission({
		revisions: store,
		close: async () => {
			attempts++;
			if (fail) throw Error('Close failed');
		}
	});
	await gate.unlock(async () => ({}));
	await expect(gate.lock()).rejects.toThrow('Close failed');
	await expect(gate.run(async () => 1)).rejects.toThrow('locked');
	fail = false;
	await gate.lock();
	expect(attempts).toBe(2);
});

test('durable revision read failure revokes an unlocked resource', async () => {
	let fail = false;
	const base = revisions();
	const store = {
		...base,
		read: async () => {
			if (fail) throw Error('Revision unavailable');
			return base.read();
		}
	};
	const { gate, open, closed } = fixture(store);
	await open();
	fail = true;
	await expect(gate.run(async () => 1)).rejects.toThrow();
	expect(gate.state).not.toBe('unlocked');
	expect(closed).toEqual([1]);
});
test('an unchanged peer notification does not cancel a current unlock', async () => {
	let notify = () => {};
	const base = revisions();
	const store = {
		...base,
		subscribe: (f: () => void) => {
			notify = f;
			return () => {};
		}
	};
	const { gate } = fixture(store);
	const started = deferred<void>(),
		pending = deferred<{ id: number }>();
	const opening = gate.unlock(() => {
		started.resolve();
		return pending.promise;
	});
	await started.promise;
	notify();
	await Promise.resolve();
	pending.resolve({ id: 1 });
	await opening;
	expect(await gate.run(async (r) => r.id)).toBe(1);
});

test.each([-1, NaN, Infinity, 1.5, Number.MAX_SAFE_INTEGER + 1])(
	'invalid durable revision %s never admits resources',
	async (value) => {
		const store = {
			read: async () => value,
			advance: async () => value,
			subscribe: () => () => {}
		};
		const { gate } = fixture(store);
		let called = false;
		await expect(
			gate.unlock(async () => {
				called = true;
				return { id: 1 };
			})
		).rejects.toThrow();
		expect(called).toBe(false);
		expect(gate.state).toBe('locked');
	}
);

test('closing locally rejects late delivery even without a durable revision change', async () => {
	const { gate, open } = fixture();
	await open();
	const started = deferred<void>(),
		held = deferred<string>();
	const result = gate.run(async () => {
		started.resolve();
		return held.promise;
	});
	await started.promise;
	const rejected = expect(result).rejects.toThrow('locked');
	await gate.close();
	held.resolve('private');
	await rejected;
});
