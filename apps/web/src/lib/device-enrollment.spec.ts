import { afterEach, describe, expect, it, vi } from 'vitest';
import { webcrypto, createHash } from 'node:crypto';
import { createCoreHandlers } from 'iris-core/client';
import {
	DeviceEnrollment,
	createCandidate,
	sessionRequest,
	type EnrollmentState
} from './device-enrollment';

const connection = { endpoint: 'https://hub.example.test', token: 'lt_fixture' };
const json = (data: unknown, status = 200, headers: Record<string, string> = {}) =>
	new Response(JSON.stringify(data), {
		status,
		headers: { 'Content-Type': 'application/json', ...headers }
	});
const deferred = <T>() => {
	let resolve!: (v: T) => void;
	const promise = new Promise<T>((r) => (resolve = r));
	return { promise, resolve };
};
const core = createCoreHandlers(
	{} as never,
	() => {
		throw Error('no network');
	},
	'test'
);
const policy = {
	async request(method: string, args: never): Promise<any> {
		if (method === 'enrollmentEndpoint') return (args as { endpoint: string }).endpoint;
		return (core as any)[method](args);
	}
};
function harness(fetcher: typeof fetch = vi.fn(async () => json({}, 401)) as typeof fetch) {
	const states: EnrollmentState[] = [];
	const install = vi.fn(async (_connection: typeof connection, current: () => boolean) => {
		if (!current()) throw Error('stale');
	});
	const model = new DeviceEnrollment({
		core: policy,
		fetch: fetcher,
		crypto: webcrypto as Crypto,
		changed: (s) => states.push(s),
		install
	});
	return { model, states, install };
}
afterEach(() => vi.useRealTimers());

describe('browser enrollment host', () => {
	it('a fresh workspace controller resets inherited pending presentation', () => {
		let pending = true;
		new DeviceEnrollment({
			core: policy,
			crypto: webcrypto as Crypto,
			fetch: vi.fn(),
			install: vi.fn(),
			changed: (s) => {
				pending = ['generating', 'pending', 'connecting'].includes(s.phase);
			}
		});
		expect(pending).toBe(false);
	});
	it('uses the platform secure random source for exactly 24 bytes', async () => {
		const random = vi.fn((a: Uint8Array<ArrayBuffer>) => webcrypto.getRandomValues(a));
		await createCandidate({
			getRandomValues: random,
			subtle: webcrypto.subtle
		} as unknown as Crypto);
		expect(random).toHaveBeenCalledTimes(1);
		expect(random.mock.calls[0][0].byteLength).toBe(24);
	});
	it('rejects unsupported HTTP methods before sending a bearer', async () => {
		const fetcher = vi.fn();
		await expect(
			sessionRequest(connection, 'DELETE' as never, new AbortController().signal, fetcher)
		).rejects.toThrow('Invalid session method');
		expect(fetcher).not.toHaveBeenCalled();
	});
	it('generates a fresh 24-byte token and SHA-256 of the entire bearer', async () => {
		const a = await createCandidate(webcrypto as Crypto),
			b = await createCandidate(webcrypto as Crypto);
		expect(a.token).toMatch(/^lt_[0-9a-f]{48}$/);
		expect(a.token).not.toBe(b.token);
		expect(a.fingerprint).toBe(createHash('sha256').update(a.token).digest('hex'));
	});
	it('uses only fixed session routes with omitted cookies and refused redirects', async () => {
		const fetcher = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) =>
			json({ name: 'device:example', scopes: ['full'] })
		);
		await sessionRequest(connection, 'GET', new AbortController().signal, fetcher);
		await sessionRequest(connection, 'POST', new AbortController().signal, fetcher);
		expect(fetcher.mock.calls.map((call) => (call as any)[0])).toEqual([
			connection.endpoint + '/v1/session',
			connection.endpoint + '/v1/session'
		]);
		expect(fetcher.mock.calls[0]?.[1]).toMatchObject({
			method: 'GET',
			redirect: 'error',
			credentials: 'omit',
			cache: 'no-store',
			headers: { Authorization: 'Bearer lt_fixture' }
		});
		expect(fetcher.mock.calls[1]?.[1]).toMatchObject({ method: 'POST', body: '{}' });
	});
	it.each([
		'http://untrusted.test',
		'https://user:secret@hub.test',
		'https://hub.test/?token=secret',
		'https://hub.test/#secret'
	])('rejects %s before HTTP', async (endpoint) => {
		const fetcher = vi.fn();
		await expect(
			sessionRequest({ ...connection, endpoint }, 'GET', new AbortController().signal, fetcher)
		).rejects.toThrow('invalid hub endpoint');
		expect(fetcher).not.toHaveBeenCalled();
	});
	it('returns typed 401 and Retry-After 503 without interpreting error bodies', async () => {
		expect(
			await sessionRequest(connection, 'GET', new AbortController().signal, async () =>
				json({ private: 'ignored' }, 401)
			)
		).toEqual({ status: 401, data: { private: 'ignored' } });
		expect(
			await sessionRequest(connection, 'GET', new AbortController().signal, async () =>
				json({}, 503, { 'Retry-After': '17' })
			)
		).toEqual({ status: 503, data: {}, retryAfterSeconds: 17 });
	});
	it('sanitizes transport/JSON failures and refuses redirected responses', async () => {
		const signal = new AbortController().signal;
		await expect(
			sessionRequest(connection, 'GET', signal, async () => {
				throw Error('lt_fixture https://private.test');
			})
		).rejects.toThrow(/^Hub session request failed\.$/);
		await expect(
			sessionRequest(
				connection,
				'GET',
				signal,
				async () => new Response('lt_fixture', { headers: { 'Content-Type': 'application/json' } })
			)
		).rejects.toThrow(/^Invalid hub session response\.$/);
		const response = json({});
		Object.defineProperty(response, 'redirected', { value: true });
		await expect(sessionRequest(connection, 'GET', signal, async () => response)).rejects.toThrow(
			'Invalid hub session response'
		);
	});
	it('bounds streaming response bytes even without Content-Length', async () => {
		let cancelled = false;
		let chunks = 0;
		const body = new ReadableStream({
			pull(c) {
				if (++chunks <= 3) c.enqueue(new Uint8Array(40000));
				else c.close();
			},
			cancel() {
				cancelled = true;
			}
		});
		await expect(
			sessionRequest(
				connection,
				'GET',
				new AbortController().signal,
				async () => new Response(body, { headers: { 'Content-Type': 'application/json' } })
			)
		).rejects.toThrow('Invalid hub session response');
		expect(cancelled).toBe(true);
	});
	it('rejects non-JSON session responses', async () => {
		await expect(
			sessionRequest(
				connection,
				'GET',
				new AbortController().signal,
				async () => new Response('ok')
			)
		).rejects.toThrow('Invalid hub session response');
	});
	it('uses real core policy to approve exact identity, then installs eligible session', async () => {
		let fingerprint = '';
		const { model, states, install } = harness(
			vi.fn(async (_url, init) => {
				fingerprint = createHash('sha256')
					.update((init!.headers as any).Authorization.slice(7))
					.digest('hex');
				return json({ name: 'device:' + fingerprint, scopes: ['full'] });
			}) as typeof fetch
		);
		await model.start(connection.endpoint, ' Example device ');
		const pending = states.find((s) => s.approval)!;
		expect(pending.approval?.url).toBe(
			connection.endpoint + '/login?key=' + fingerprint + '&name=Example%20device'
		);
		expect(pending.approval?.code).toBe(fingerprint.slice(0, 8));
		expect(JSON.stringify(states)).not.toContain('lt_');
		expect(install).toHaveBeenCalledTimes(1);
		expect(states.at(-1)?.phase).toBe('connected');
	});
	it.each([
		{ name: 'admin', scopes: ['admin'] },
		{ name: 'device:manual', scopes: ['tables:read'] },
		{ name: 'device:manual', scopes: ['full'], capabilities: { replica_sync: false } }
	])('rejects manual ineligible/admin identity without installation: %j', async (data) => {
		const { model, states, install } = harness(async () => json(data));
		await model.manual(connection);
		expect(install).not.toHaveBeenCalled();
		expect(states.at(-1)?.phase).toBe('failed');
	});
	it('validates manual dedicated full identity through core', async () => {
		const { model, install } = harness(async () =>
			json({ name: 'dedicated-client', scopes: ['full'] })
		);
		await model.manual(connection);
		expect(install).toHaveBeenCalledTimes(1);
	});
	it('a success-shaped unauthorized reply cannot validate a manual token', async () => {
		const { model, install, states } = harness(async () =>
			json({ name: 'dedicated-client', scopes: ['full'] }, 401)
		);
		await model.manual(connection);
		expect(install).not.toHaveBeenCalled();
		expect(states.at(-1)?.message).toContain('HTTP 401');
	});
	it('an old cleanup finishing after replacement cannot overwrite connected state', async () => {
		const cleanup = deferred<Response>();
		let gets = 0,
			oldStarted = false;
		const { model, states, install } = harness(async (_url, init) => {
			if (init?.method === 'POST') {
				oldStarted = true;
				return cleanup.promise;
			}
			if (++gets === 1) return json({}, 401);
			const fp = createHash('sha256')
				.update((init!.headers as any).Authorization.slice(7))
				.digest('hex');
			return json({ name: 'device:' + fp, scopes: ['full'] });
		});
		const first = model.start(connection.endpoint, 'One');
		await vi.waitFor(() => expect(gets).toBe(1));
		await model.start(connection.endpoint, 'Two');
		expect(oldStarted).toBe(true);
		expect(states.at(-1)?.phase).toBe('connected');
		cleanup.resolve(json({ logged_out: true }));
		await first;
		await new Promise((r) => setTimeout(r, 0));
		expect(install).toHaveBeenCalledTimes(1);
		expect(states.at(-1)?.phase).toBe('connected');
	});
	it('manual unauthorized failure never revokes the supplied token', async () => {
		const fetcher = vi.fn(async () => json({}, 401));
		const { model, install } = harness(fetcher);
		await model.manual(connection);
		expect(fetcher).toHaveBeenCalledTimes(1);
		expect(install).not.toHaveBeenCalled();
	});
	it('polls with the core delay and honors Retry-After', async () => {
		vi.useFakeTimers();
		let calls = 0;
		const { model, install } = harness(async (_url, init) => {
			if (++calls === 1) return json({}, 503, { 'Retry-After': '17' });
			const fp = createHash('sha256')
				.update((init!.headers as any).Authorization.slice(7))
				.digest('hex');
			return json({ name: 'device:' + fp, scopes: ['full'] });
		});
		const run = model.start(connection.endpoint, 'Example');
		await vi.waitFor(() => expect(calls).toBe(1));
		await vi.advanceTimersByTimeAsync(16000);
		expect(calls).toBe(1);
		await vi.advanceTimersByTimeAsync(1000);
		await run;
		expect(install).toHaveBeenCalledTimes(1);
	});
	it('cancel invalidates a late approval and reports 401 as unconfirmed cleanup', async () => {
		const reply = deferred<Response>();
		let fp = '';
		const fetcher = vi.fn(async (_url, init) => {
			if (init?.method === 'POST') return json({}, 401);
			fp = createHash('sha256')
				.update((init!.headers as any).Authorization.slice(7))
				.digest('hex');
			return reply.promise;
		});
		const { model, states, install } = harness(fetcher as typeof fetch);
		const run = model.start(connection.endpoint, 'Example');
		await vi.waitFor(() => expect(fp).not.toBe(''));
		await model.cancel();
		reply.resolve(json({ name: 'device:' + fp, scopes: ['full'] }));
		await run;
		expect(install).not.toHaveBeenCalled();
		expect(states.at(-1)?.phase).toBe('cancelled');
		expect(states.at(-1)?.message).toContain('may still be approved');
	});
	it('deadline aborts pending requests and rejects approval arriving late', async () => {
		vi.useFakeTimers();
		const reply = deferred<Response>();
		let fp = '';
		let signal: AbortSignal | undefined;
		const { model, states, install } = harness(async (_url, init) => {
			if (init?.method === 'POST') return json({ logged_out: true });
			signal = init?.signal as AbortSignal;
			fp = createHash('sha256')
				.update((init!.headers as any).Authorization.slice(7))
				.digest('hex');
			return reply.promise;
		});
		const run = model.start(connection.endpoint, 'Example');
		await vi.waitFor(() => expect(fp).not.toBe(''));
		await vi.advanceTimersByTimeAsync(300001);
		expect(signal?.aborted).toBe(true);
		reply.resolve(json({ name: 'device:' + fp, scopes: ['full'] }));
		await run;
		expect(install).not.toHaveBeenCalled();
		expect(states.at(-1)?.phase).toBe('timed-out');
	});
	it('a replacement attempt ignores the old approval and its cleanup state', async () => {
		const reply = deferred<Response>();
		let old = '';
		let gets = 0;
		const { model, states, install } = harness(async (_url, init) => {
			if (init?.method === 'POST') return json({ logged_out: true });
			const fp = createHash('sha256')
				.update((init!.headers as any).Authorization.slice(7))
				.digest('hex');
			if (++gets === 1) {
				old = fp;
				return reply.promise;
			}
			return json({ name: 'device:' + fp, scopes: ['full'] });
		});
		const first = model.start(connection.endpoint, 'One');
		await vi.waitFor(() => expect(old).not.toBe(''));
		await model.start(connection.endpoint, 'Two');
		reply.resolve(json({ name: 'device:' + old, scopes: ['full'] }));
		await first;
		expect(install).toHaveBeenCalledTimes(1);
		expect(states.at(-1)?.phase).toBe('connected');
	});
	it('cancellation while host installation awaits invalidates its final publish guard', async () => {
		const gate = deferred<void>();
		let entered = false;
		let installed = false;
		const { model, install } = harness(async (_url, init) => {
			if (init?.method === 'POST') return json({ logged_out: true });
			const fp = createHash('sha256')
				.update((init!.headers as any).Authorization.slice(7))
				.digest('hex');
			return json({ name: 'device:' + fp, scopes: ['full'] });
		});
		install.mockImplementation(async (_connection, current) => {
			entered = true;
			await gate.promise;
			installed = current();
		});
		const run = model.start(connection.endpoint, 'Example');
		await vi.waitFor(() => expect(entered).toBe(true));
		await model.cancel();
		gate.resolve();
		await run;
		expect(installed).toBe(false);
	});
	it('failure to install approved candidate revokes only that candidate', async () => {
		const fetcher = vi.fn(async (_url, init) => {
			if (init?.method === 'POST') return json({ logged_out: true });
			const fp = createHash('sha256')
				.update((init!.headers as any).Authorization.slice(7))
				.digest('hex');
			return json({ name: 'device:' + fp, scopes: ['full'] });
		});
		const { model, states, install } = harness(fetcher as typeof fetch);
		install.mockRejectedValue(Error('cannot connect'));
		await model.start(connection.endpoint, 'Example');
		expect(states.at(-1)?.phase).toBe('failed');
		expect(fetcher.mock.calls.at(-1)?.[1]?.method).toBe('POST');
		expect(states.at(-1)?.message).toContain('revoked');
	});
	it('malformed session JSON stops approval instead of quietly polling again', async () => {
		vi.useFakeTimers();
		const { model, states, install } = harness(
			async () => new Response('not JSON', { headers: { 'Content-Type': 'application/json' } })
		);
		const run = model.start(connection.endpoint, 'Example');
		await vi.waitFor(() => expect(states.some((s) => s.approval)).toBe(true));
		await vi.advanceTimersByTimeAsync(1000);
		expect(states.at(-1)?.phase).toBe('failed');
		expect(install).not.toHaveBeenCalled();
		await model.cancel();
		await run;
	});
	it('binding preflight fails before approval or any HTTP', async () => {
		const fetcher = vi.fn();
		const states: EnrollmentState[] = [];
		const model = new DeviceEnrollment({
			core: {
				request: async () => {
					throw Error('hub changed; use a fresh replica');
				}
			} as never,
			fetch: fetcher,
			crypto: webcrypto as Crypto,
			changed: (s) => states.push(s),
			install: vi.fn()
		});
		await model.start(connection.endpoint, 'Example');
		await model.manual(connection);
		expect(fetcher).not.toHaveBeenCalled();
		expect(states.some((s) => s.approval)).toBe(false);
	});
});
