import { CORE_CONTRACT_HASH } from 'iris-core/contract';
import { expect, test } from 'bun:test';
const { createJournalChannel, serveJournalChannel } = (await import(
	process.env.IRIS_TEST_JOURNAL_CHANNEL || '../apps/web/src/lib/governance/journal-channel'
)) as typeof import('../apps/web/src/lib/governance/journal-channel');
import type { JournalRequest, JournalReply } from '../apps/web/src/lib/governance/journal-protocol';
function fixture(
	request: (value: unknown) => Promise<JournalReply> = async (value) =>
		(value as JournalRequest).method === 'open' ? 'opaque-handle' : null
) {
	const pair = new MessageChannel(),
		controller = new AbortController();
	let hostClosed = 0,
		disposed = 0,
		terminated = 0;
	const server = serveJournalChannel(
		pair.port2,
		{ request, close: () => hostClosed++ },
		{
			signal: controller.signal,
			dispose: () => {
				disposed++;
			}
		}
	);
	const client = createJournalChannel(pair.port1, {
		signal: controller.signal,
		timeoutMs: 100,
		terminate: () => {
			terminated++;
		}
	});
	return {
		pair,
		server,
		client,
		controller,
		get hostClosed() {
			return hostClosed;
		},
		get disposed() {
			return disposed;
		},
		get terminated() {
			return terminated;
		},
		async cleanup() {
			await server.close();
			try {
				await client.close();
			} catch {}
			pair.port1.close();
			pair.port2.close();
		}
	};
}
test('actual MessageChannel carries typed requests and structured clone without caller identity or credentials', async () => {
	const wire: unknown[] = [];
	const f = fixture(async (request) => {
		wire.push(request);
		return (request as JournalRequest).method === 'open' ? 'opaque-handle' : null;
	});
	try {
		expect(await f.client.request({ method: 'open', kind: 'governance' })).toBe('opaque-handle');
		await f.client.request({ method: 'load', handle: 'opaque-handle' });
		expect(wire).toEqual([
			{ method: 'open', kind: 'governance' },
			{ method: 'load', handle: 'opaque-handle' }
		]);
		await f.client.close();
		expect(f.terminated).toBe(1);
		expect(f.hostClosed).toBe(1);
		expect(f.disposed).toBe(1);
	} finally {
		await f.cleanup();
	}
});
test('graceful channel close drains prior work and denies new requests', async () => {
	let release!: () => void, started!: () => void;
	const entered = new Promise<void>((res) => (started = res)),
		blocked = new Promise<void>((res) => (release = res));
	let committed = false;
	const f = fixture(async () => {
		started();
		await blocked;
		committed = true;
		return null;
	});
	try {
		const pending = f.client.request({ method: 'load', handle: 'opaque-handle' });
		await entered;
		let received!: () => void;
		const shutdownReceived = new Promise<void>((resolve) => (received = resolve));
		f.pair.port2.addEventListener('message', (event) => {
			if (event.data.type === 'shutdown') received();
		});
		const closing = f.client.close();
		await expect(f.client.request({ method: 'open', kind: 'governance' })).rejects.toThrow();
		await shutdownReceived;
		expect(f.hostClosed).toBe(0);
		expect(f.terminated).toBe(0);
		release();
		expect(await pending).toBeNull();
		await closing;
		expect(committed).toBe(true);
		expect(f.hostClosed).toBe(1);
		expect(f.terminated).toBe(1);
	} finally {
		release?.();
		await f.cleanup();
	}
});
test('silent closed port times out, rejects uncertainty, terminates owner once and never retries', async () => {
	const pair = new MessageChannel(),
		controller = new AbortController();
	let terminated = 0;
	pair.port2.close();
	const client = createJournalChannel(pair.port1, {
		signal: controller.signal,
		timeoutMs: 10,
		terminate: () => {
			terminated++;
		}
	});
	try {
		await expect(
			client.request({ method: 'retain', handle: 'opaque-handle', entry: {} as never })
		).rejects.toThrow();
		await expect(client.request({ method: 'open', kind: 'governance' })).rejects.toThrow();
		expect(terminated).toBe(1);
	} finally {
		try {
			await client.close();
		} catch {}
		pair.port1.close();
	}
});
test('noncloneable request causes fail-closed channel loss and owner termination', async () => {
	const f = fixture();
	try {
		await expect(
			f.client.request({
				method: 'retain',
				handle: 'opaque-handle',
				entry: { callback: () => {} } as never
			})
		).rejects.toThrow();
		expect(f.terminated).toBe(1);
		await expect(f.client.request({ method: 'load', handle: 'opaque-handle' })).rejects.toThrow();
	} finally {
		await f.cleanup();
	}
});
test('worker messageerror closes host, calls owner disposal and rejects pending client work', async () => {
	let started!: () => void;
	const entered = new Promise<void>((res) => (started = res));
	const f = fixture(async () => {
		started();
		return new Promise(() => {});
	});
	try {
		const pending = f.client.request({ method: 'load', handle: 'opaque-handle' });
		await entered;
		f.pair.port2.dispatchEvent(new MessageEvent('messageerror'));
		await expect(pending).rejects.toThrow();
		expect(f.hostClosed).toBe(1);
		expect(f.disposed).toBe(1);
		expect(f.terminated).toBe(1);
	} finally {
		await f.cleanup();
	}
});
test('owner abort closes both ends and no stale reply can acknowledge work', async () => {
	let release!: () => void, started!: () => void;
	const entered = new Promise<void>((res) => (started = res)),
		blocked = new Promise<void>((res) => (release = res));
	const f = fixture(async () => {
		started();
		await blocked;
		return null;
	});
	try {
		const pending = f.client.request({ method: 'load', handle: 'opaque-handle' });
		await entered;
		f.controller.abort();
		expect(f.terminated).toBe(1);
		await expect(pending).rejects.toThrow();
		release();
		expect(f.terminated).toBe(1);
		expect(f.hostClosed).toBe(1);
		expect(f.disposed).toBe(1);
	} finally {
		release?.();
		await f.cleanup();
	}
});
test('client never acknowledges successful cleanup when its worker termination callback fails', async () => {
	const pair = new MessageChannel(),
		controller = new AbortController();
	const server = serveJournalChannel(
		pair.port2,
		{ request: async () => null, close: () => {} },
		{ signal: controller.signal, dispose: () => {} }
	);
	const client = createJournalChannel(pair.port1, {
		signal: controller.signal,
		timeoutMs: 100,
		terminate: () => {
			throw Error('synthetic termination failed');
		}
	});
	try {
		await expect(client.close()).rejects.toThrow();
		expect(client.cleanupError).toBeDefined();
	} finally {
		await server.close();
		pair.port1.close();
		pair.port2.close();
	}
});

test('malformed worker reply fails the whole channel rather than resolving a pending request', async () => {
	const pair = new MessageChannel(),
		controller = new AbortController();
	let terminated = 0;
	pair.port2.onmessage = () =>
		pair.port2.postMessage({
			protocol: 'wrong',
			contractHash: CORE_CONTRACT_HASH,
			contractHash: CORE_CONTRACT_HASH,
			id: 1,
			ok: true,
			result: 'forged'
		});
	const client = createJournalChannel(pair.port1, {
		signal: controller.signal,
		timeoutMs: 100,
		terminate: () => {
			terminated++;
		}
	});
	try {
		await expect(client.request({ method: 'open', kind: 'governance' })).rejects.toThrow();
		expect(terminated).toBe(1);
	} finally {
		try {
			await client.close();
		} catch {}
		pair.port1.close();
		pair.port2.close();
	}
});
test('worker errors never forward arbitrary credential-shaped error text to the page', async () => {
	const f = fixture(async () => {
		throw Error('synthetic-consumer-secret');
	});
	try {
		let message = '';
		try {
			await f.client.request({ method: 'open', kind: 'governance' });
		} catch (error) {
			message = (error as Error).message;
		}
		expect(message).toContain('failed');
		expect(message).not.toContain('synthetic-consumer-secret');
		await f.client.close();
	} finally {
		await f.cleanup();
	}
});
test('replayed request sequence closes the host instead of dispatching a duplicate mutation', async () => {
	const { JOURNAL_CHANNEL_PROTOCOL } =
		await import('../apps/web/src/lib/governance/journal-channel');
	const pair = new MessageChannel(),
		controller = new AbortController();
	let release!: () => void,
		started!: () => void,
		closed = 0,
		disposed = 0,
		calls = 0;
	const entered = new Promise<void>((res) => (started = res)),
		blocked = new Promise<void>((res) => (release = res));
	const frames: unknown[] = [];
	let terminal!: () => void;
	const stopped = new Promise<void>((res) => (terminal = res));
	pair.port1.onmessage = (event) => {
		frames.push(event.data);
		if (event.data.type === 'closed') terminal();
	};
	const server = serveJournalChannel(
		pair.port2,
		{
			request: async () => {
				calls++;
				started();
				await blocked;
				return null;
			},
			close: () => {
				closed++;
			}
		},
		{
			signal: controller.signal,
			dispose: () => {
				disposed++;
			}
		}
	);
	const frame = {
		protocol: JOURNAL_CHANNEL_PROTOCOL,
		contractHash: CORE_CONTRACT_HASH,
		id: 1,
		type: 'request',
		request: { method: 'load', handle: 'opaque-handle' }
	};
	try {
		pair.port1.postMessage(frame);
		await entered;
		pair.port1.postMessage(frame);
		let deadline: ReturnType<typeof setTimeout> | undefined;
		try {
			const observed = await Promise.race([
				stopped.then(() => true),
				new Promise<boolean>((resolve) => (deadline = setTimeout(() => resolve(false), 500)))
			]);
			expect(observed).toBe(true);
		} finally {
			clearTimeout(deadline);
		}
		release();
		expect(calls).toBe(1);
		expect(closed).toBe(1);
		expect(disposed).toBe(1);
		expect(frames).toEqual([
			{ protocol: JOURNAL_CHANNEL_PROTOCOL, contractHash: CORE_CONTRACT_HASH, type: 'closed' }
		]);
	} finally {
		release?.();
		await server.close();
		pair.port1.close();
		pair.port2.close();
	}
});
test('failed worker host close cannot be acknowledged as a successful channel shutdown', async () => {
	const pair = new MessageChannel(),
		controller = new AbortController();
	let terminated = 0,
		disposed = 0;
	const server = serveJournalChannel(
		pair.port2,
		{
			request: async () => null,
			close: () => {
				throw Error('synthetic host close failed');
			}
		},
		{
			signal: controller.signal,
			dispose: () => {
				disposed++;
			}
		}
	);
	const client = createJournalChannel(pair.port1, {
		signal: controller.signal,
		timeoutMs: 100,
		terminate: () => {
			terminated++;
		}
	});
	try {
		await expect(client.close()).rejects.toThrow();
		expect(terminated).toBe(1);
		expect(disposed).toBe(1);
		expect(server.cleanupError).toBeDefined();
	} finally {
		try {
			await server.close();
		} catch {}
		pair.port1.close();
		pair.port2.close();
	}
});
test('actual canonical worker host/admission and typed proxy round trip across MessageChannel', async () => {
	const { createWorkspaceAdmission } = await import('../apps/web/src/lib/workspace-admission');
	const { createWorkerJournalHost } = await import('../apps/web/src/lib/governance/worker-journal');
	const { openJournalProxy } = await import('../apps/web/src/lib/governance/journal-proxy');
	const scope = {
			deploymentId: 'deployment-1',
			sessionId: 'session-1',
			principalId: 'principal-1'
		},
		root = new Uint8Array(32).fill(49),
		values = new Map<string, unknown>();
	let revision = 0,
		terminated = 0;
	const capability = {
		deploymentId: scope.deploymentId,
		sessionId: scope.sessionId,
		protocol: 'selected-inverse-proposals-v1',
		principal: { kind: 'user', principalId: scope.principalId },
		authority: { propose: true, approve: true },
		limits: {
			maxSelectedEvents: 100,
			maxChangedColumns: 64,
			maxRequestBytes: 65536,
			maxPageSize: 100,
			previewTtlSeconds: 300
		}
	};
	const admission = createWorkspaceAdmission({
		revisions: {
			read: async () => revision,
			advance: async () => ++revision,
			subscribe: () => () => {}
		},
		close: async () => host.close()
	});
	const host = createWorkerJournalHost({
		admission,
		openStore: async (key, codec) => ({
			load: async () => (values.has(key) ? codec.decode(structuredClone(values.get(key))) : null),
			retain: async (value) => {
				const next = codec.encode(value);
				if (values.has(key) && !codec.equal(values.get(key), next)) throw Error('changed');
				values.set(key, structuredClone(next));
			},
			resolve: async (value) => {
				if (values.has(key) && !codec.equal(values.get(key), codec.encode(value)))
					throw Error('changed');
				values.delete(key);
			},
			close: () => {}
		})
	});
	await admission.unlock(async () => ({
		root,
		workspace: 'workspace-1',
		generation: 1,
		connection: { endpoint: 'https://example.test', capabilities: { governance: capability } }
	}));
	const pair = new MessageChannel(),
		controller = new AbortController();
	const server = serveJournalChannel(pair.port2, host, {
		signal: controller.signal,
		dispose: async () => {
			await admission.close();
			root.fill(0);
		}
	});
	const client = createJournalChannel(pair.port1, {
		signal: controller.signal,
		timeoutMs: 500,
		terminate: () => {
			terminated++;
		}
	});
	const entry = {
		version: 1 as const,
		scope,
		target: { table: 'items', rowId: 'row-1' },
		intent: { kind: 'selected_inverse' as const, eventIds: ['event-1'] },
		revision: { updated_at: '2030-01-01T00:00:00.000Z', hub_at: null },
		changes: [
			{
				column: 'amount',
				before: { type: 'integer' as const, value: '9223372036854775807' },
				after: { type: 'null' as const }
			}
		],
		selectedEventIds: ['event-1'],
		request: {
			proposalId: 'proposal-1',
			expectedVersion: 'version-1',
			previewToken: 'synthetic-preview',
			idempotencyKey: 'uncertain-original'
		}
	};
	try {
		const proxy = await openJournalProxy('governance', client.request);
		await proxy.retain(entry);
		expect(await proxy.load()).toEqual(entry);
		let scopeError: unknown;
		try {
			await proxy.retain({ ...entry, scope: { ...scope, principalId: 'forged' } });
		} catch (error) {
			scopeError = error;
		}
		expect((scopeError as Error).message).toBe('Journal worker request failed.');
		expect(await proxy.load()).toEqual(entry);
		let identityError: unknown;
		try {
			await client.request({
				method: 'open',
				kind: 'governance',
				scope: { principalId: 'forged' }
			} as never);
		} catch (error) {
			identityError = error;
		}
		expect((identityError as Error).message).toBe('Journal worker request failed.');
		expect(values.size).toBe(1);
		await proxy.close();
		await client.close();
		await server.close();
		expect(root.every((byte) => byte === 0)).toBe(true);
		expect(terminated).toBe(1);
		expect(values.size).toBe(1);
	} finally {
		await server.close();
		try {
			await client.close();
		} catch {}
		pair.port1.close();
		pair.port2.close();
	}
});

test('shutdown reply waits for asynchronous owning resource disposal, not just journal handle close', async () => {
	const pair = new MessageChannel(),
		controller = new AbortController();
	let release!: () => void,
		started!: () => void,
		acknowledged = false;
	const entered = new Promise<void>((res) => (started = res)),
		blocked = new Promise<void>((res) => (release = res));
	const post = pair.port2.postMessage.bind(pair.port2);
	pair.port2.postMessage = (frame: unknown) => {
		if ((frame as { ok?: boolean }).ok === true) acknowledged = true;
		post(frame);
	};
	const server = serveJournalChannel(
		pair.port2,
		{ request: async () => null, close: () => {} },
		{
			signal: controller.signal,
			dispose: async () => {
				started();
				await blocked;
			}
		}
	);
	const client = createJournalChannel(pair.port1, {
		signal: controller.signal,
		timeoutMs: 500,
		terminate: () => {}
	});
	try {
		const closing = client.close();
		await entered;
		expect(acknowledged).toBe(false);
		release();
		await closing;
		expect(acknowledged).toBe(true);
	} finally {
		release?.();
		await server.close();
		try {
			await client.close();
		} catch {}
		pair.port1.close();
		pair.port2.close();
	}
});
test('failed asynchronous owner disposal is never acknowledged as successful shutdown', async () => {
	const pair = new MessageChannel(),
		controller = new AbortController();
	const server = serveJournalChannel(
		pair.port2,
		{ request: async () => null, close: () => {} },
		{
			signal: controller.signal,
			dispose: async () => {
				throw Error('synthetic resource disposal failed');
			}
		}
	);
	const client = createJournalChannel(pair.port1, {
		signal: controller.signal,
		timeoutMs: 100,
		terminate: () => {}
	});
	try {
		let failure: unknown;
		try {
			await client.close();
		} catch (error) {
			failure = error;
		}
		expect(failure).toBeInstanceOf(Error);
		expect(server.cleanupError).toBeDefined();
	} finally {
		try {
			await server.close();
		} catch {}
		pair.port1.close();
		pair.port2.close();
	}
});

test('channel compatibility frames bind the existing canonical core contract hash', async () => {
	const f = fixture();
	const hashes: unknown[] = [];
	f.pair.port2.addEventListener('message', (event) => hashes.push(event.data.contractHash));
	try {
		await f.client.request({ method: 'open', kind: 'governance' });
		expect(hashes).toEqual([CORE_CONTRACT_HASH]);
		await f.client.close();
		expect(hashes[1]).toBe(CORE_CONTRACT_HASH);
	} finally {
		await f.cleanup();
	}
});

test('mismatched worker core contract cannot acknowledge a correctly shaped reply', async () => {
	const { JOURNAL_CHANNEL_PROTOCOL } =
		await import('../apps/web/src/lib/governance/journal-channel');
	const pair = new MessageChannel(),
		controller = new AbortController();
	let terminated = 0;
	pair.port2.onmessage = (event) =>
		pair.port2.postMessage({
			protocol: JOURNAL_CHANNEL_PROTOCOL,
			contractHash: 'different-core',
			id: event.data.id,
			ok: true,
			result: 'forged-handle'
		});
	const client = createJournalChannel(pair.port1, {
		signal: controller.signal,
		timeoutMs: 100,
		terminate: () => {
			terminated++;
		}
	});
	try {
		let error: unknown;
		try {
			await client.request({ method: 'open', kind: 'governance' });
		} catch (value) {
			error = value;
		}
		expect(error).toBeInstanceOf(Error);
		expect(terminated).toBe(1);
	} finally {
		try {
			await client.close();
		} catch {}
		pair.port1.close();
		pair.port2.close();
	}
});
test('mismatched page core contract never dispatches into the worker host', async () => {
	const { JOURNAL_CHANNEL_PROTOCOL } =
		await import('../apps/web/src/lib/governance/journal-channel');
	const pair = new MessageChannel(),
		controller = new AbortController();
	let calls = 0,
		disposed = 0,
		received!: () => void;
	const closed = new Promise<void>((res) => (received = res));
	pair.port1.onmessage = () => received();
	const server = serveJournalChannel(
		pair.port2,
		{
			request: async () => {
				calls++;
				return null;
			},
			close: () => {}
		},
		{
			signal: controller.signal,
			dispose: () => {
				disposed++;
			}
		}
	);
	try {
		pair.port1.postMessage({
			protocol: JOURNAL_CHANNEL_PROTOCOL,
			contractHash: 'different-core',
			id: 1,
			type: 'request',
			request: { method: 'open', kind: 'governance' }
		});
		await closed;
		expect(calls).toBe(0);
		expect(disposed).toBe(1);
	} finally {
		await server.close();
		pair.port1.close();
		pair.port2.close();
	}
});
