import {
	createHttpHub,
	ENROLLMENT_POLICY,
	type CoreArgs,
	type CoreResult,
	type SessionReply
} from 'life-ui-core/client';

export interface HubConnection {
	endpoint: string;
	token: string;
}
type PolicyMethod =
	| 'enrollmentApproval'
	| 'validateDeviceSession'
	| 'enrollmentPollResult'
	| 'sessionRevocationResult';
export interface EnrollmentCore {
	request<M extends PolicyMethod>(method: M, args: CoreArgs<M>): Promise<CoreResult<M>>;
	request(method: 'enrollmentEndpoint', args: { endpoint: string }): Promise<string>;
}
export interface EnrollmentState {
	phase:
		| 'idle'
		| 'generating'
		| 'pending'
		| 'connecting'
		| 'connected'
		| 'failed'
		| 'cancelled'
		| 'timed-out';
	message: string;
	approval?: { url: string; code: string };
}
export async function createCandidate(random: Crypto = crypto) {
	const bytes = random.getRandomValues(new Uint8Array(24));
	const hex = (value: Uint8Array) =>
		Array.from(value, (b) => b.toString(16).padStart(2, '0')).join('');
	const token = 'lt_' + hex(bytes);
	const fingerprint = hex(
		new Uint8Array(await random.subtle.digest('SHA-256', new TextEncoder().encode(token)))
	);
	return { token, fingerprint };
}

class SessionTransportError extends Error {}

/** Fixed endpoint, typed status, bounded bytes. Policy remains in generated core operations. */
export async function sessionRequest(
	connection: HubConnection,
	method: 'GET' | 'POST',
	signal: AbortSignal,
	fetcher: typeof fetch = fetch
): Promise<SessionReply> {
	if (method !== 'GET' && method !== 'POST') throw new Error('Invalid session method.');
	const endpoint = createHttpHub(connection.endpoint, connection.token, fetcher).endpoint;
	let response: Response;
	try {
		response = await fetcher(endpoint + '/v1/session', {
			method,
			signal,
			redirect: 'error',
			credentials: 'omit',
			cache: 'no-store',
			headers: {
				Authorization: 'Bearer ' + connection.token,
				Accept: 'application/json',
				...(method === 'POST' ? { 'Content-Type': 'application/json' } : {})
			},
			...(method === 'POST' ? { body: '{}' } : {})
		});
	} catch {
		throw new SessionTransportError('Hub session request failed.');
	}
	let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
	try {
		if (response.redirected || (response.url && response.url !== endpoint + '/v1/session'))
			throw Error();
		const type = response.headers.get('Content-Type')?.split(';')[0].trim().toLowerCase();
		if (
			type !== 'application/json' &&
			!(type?.startsWith('application/') && type.endsWith('+json'))
		)
			throw Error();
		if (Number(response.headers.get('Content-Length')) > ENROLLMENT_POLICY.maxResponseBytes)
			throw Error();
		reader = response.body?.getReader();
		if (!reader) throw Error();
		let length = 0;
		const chunks: Uint8Array[] = [];
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			length += value.byteLength;
			if (length > ENROLLMENT_POLICY.maxResponseBytes) throw Error();
			chunks.push(value);
		}
		const bytes = new Uint8Array(length);
		let offset = 0;
		for (const chunk of chunks) {
			bytes.set(chunk, offset);
			offset += chunk.byteLength;
		}
		const data = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
		const raw = response.headers.get('Retry-After');
		const retry =
			raw && /^\d+$/.test(raw)
				? Number(raw)
				: raw
					? Math.max(0, Math.ceil((Date.parse(raw) - Date.now()) / 1000))
					: NaN;
		return {
			status: response.status,
			data,
			...(Number.isSafeInteger(retry) && retry >= 0 ? { retryAfterSeconds: retry } : {})
		};
	} catch {
		await reader?.cancel().catch(() => {});
		throw new Error('Invalid hub session response.');
	} finally {
		reader?.releaseLock();
	}
}

interface Attempt {
	controller: AbortController;
	deadline: number;
	timer: ReturnType<typeof setTimeout>;
	candidate?: HubConnection;
	approval?: EnrollmentState['approval'];
	cleanup?: Promise<string>;
}
const cleanupUnknown =
	'The approval link may still be approved later. Cancel it or revoke the device through the hub if needed.';
export class DeviceEnrollment {
	private active: Attempt | null = null;
	private readonly fetcher: typeof fetch;
	private readonly random: Crypto;
	constructor(
		private readonly host: {
			core: EnrollmentCore;
			install(connection: HubConnection, current: () => boolean): Promise<void>;
			changed(state: EnrollmentState): void;
			fetch?: typeof fetch;
			crypto?: Crypto;
		}
	) {
		this.fetcher = host.fetch ?? fetch;
		this.random = host.crypto ?? crypto;
	}
	private current(a: Attempt) {
		return this.active === a && !a.controller.signal.aborted && performance.now() < a.deadline;
	}
	private begin(phase: EnrollmentState['phase']) {
		void this.cancel();
		const a: Attempt = {
			controller: new AbortController(),
			deadline: performance.now() + ENROLLMENT_POLICY.timeoutSeconds * 1000,
			timer: undefined!
		};
		a.timer = setTimeout(() => {
			if (this.active === a) void this.stop(a, 'timed-out', 'Approval timed out.');
		}, ENROLLMENT_POLICY.timeoutSeconds * 1000);
		this.active = a;
		this.host.changed({
			phase,
			message: phase === 'generating' ? 'Preparing device approval…' : 'Checking device token…'
		});
		return a;
	}
	private async cleanup(a: Attempt): Promise<string> {
		if (!a.candidate) return '';
		if (!a.cleanup)
			a.cleanup = (async () => {
				const controller = new AbortController(),
					timer = setTimeout(() => controller.abort(), 10000);
				try {
					const reply = await sessionRequest(a.candidate!, 'POST', controller.signal, this.fetcher);
					const result = await this.host.core.request('sessionRevocationResult', reply);
					return result.state === 'revoked'
						? 'The candidate device token was revoked.'
						: cleanupUnknown;
				} catch {
					return 'Cleanup could not be confirmed. ' + cleanupUnknown;
				} finally {
					clearTimeout(timer);
				}
			})();
		return a.cleanup;
	}
	private async stop(a: Attempt, phase: 'cancelled' | 'timed-out' | 'failed', message: string) {
		a.controller.abort();
		clearTimeout(a.timer);
		if (this.active === a)
			this.host.changed({ phase, message: message + ' ' + (a.candidate ? cleanupUnknown : '') });
		const cleanup = await this.cleanup(a);
		if (this.active === a)
			this.host.changed({ phase, message: [message, cleanup].filter(Boolean).join(' ') });
	}
	async cancel() {
		const a = this.active;
		if (a) await this.stop(a, 'cancelled', 'Approval stopped.');
	}
	private async install(
		a: Attempt,
		connection: HubConnection,
		session: CoreResult<'validateDeviceSession'>
	) {
		if (!this.current(a)) return;
		if (!session.replica.allowed)
			throw Error(session.replica.reason?.message ?? 'This device token cannot sync a replica.');
		this.host.changed({ phase: 'connecting', message: 'Connecting this workspace…' });
		await this.host.install(connection, () => this.current(a));
		if (!this.current(a)) return;
		clearTimeout(a.timer);
		a.candidate = undefined;
		this.active = null;
		this.host.changed({
			phase: 'connected',
			message: 'Connected. The device token stays in memory for this browser session.'
		});
	}
	async start(endpoint: string, name: string) {
		const a = this.begin('generating');
		try {
			// Validate the address without sending a credential. Replica binding is checked before a link is shown.
			endpoint = createHttpHub(endpoint, 'endpoint-check', this.fetcher).endpoint;
			endpoint = await this.host.core.request('enrollmentEndpoint', { endpoint });
			if (!this.current(a)) return;
			const { token, fingerprint } = await createCandidate(this.random);
			if (!this.current(a)) return;
			const approval = await this.host.core.request('enrollmentApproval', { fingerprint, name });
			if (!this.current(a)) return;
			a.candidate = { endpoint, token };
			a.approval = { url: endpoint + approval.path, code: approval.approvalCode };
			this.host.changed({
				phase: 'pending',
				message: 'Approve this device at your hub, then return here.',
				approval: a.approval
			});
			while (this.current(a)) {
				let reply: SessionReply;
				try {
					reply = await sessionRequest(a.candidate, 'GET', a.controller.signal, this.fetcher);
				} catch (e) {
					if (!this.current(a)) return;
					if (!(e instanceof SessionTransportError)) throw e;
					await this.wait(a, ENROLLMENT_POLICY.pollIntervalSeconds);
					continue;
				}
				if (!this.current(a)) return;
				const result = await this.host.core.request('enrollmentPollResult', {
					reply,
					expectedFingerprint: fingerprint
				});
				if (!this.current(a)) return;
				if (result.state === 'approved') {
					await this.install(a, a.candidate, result.session!);
					return;
				}
				await this.wait(a, result.retryAfterSeconds!);
			}
		} catch (e) {
			if (this.current(a))
				await this.stop(a, 'failed', e instanceof Error ? e.message : 'Device approval failed.');
		}
	}
	async manual(connection: HubConnection) {
		const a = this.begin('connecting');
		try {
			const endpoint = createHttpHub(connection.endpoint, connection.token, this.fetcher).endpoint;
			await this.host.core.request('enrollmentEndpoint', { endpoint });
			if (!this.current(a)) return;
			const reply = await sessionRequest(
				{ ...connection, endpoint },
				'GET',
				a.controller.signal,
				this.fetcher
			);
			if (!this.current(a)) return;
			if (reply.status !== 200) throw Error('hub HTTP ' + reply.status);
			const session = await this.host.core.request('validateDeviceSession', { data: reply.data });
			if (!this.current(a)) return;
			await this.install(a, { ...connection, endpoint }, session);
		} catch (e) {
			if (this.current(a))
				await this.stop(
					a,
					'failed',
					e instanceof Error ? e.message : 'Device token validation failed.'
				);
		}
	}
	private wait(a: Attempt, seconds: number) {
		return new Promise<void>((resolve) => {
			const signal = a.controller.signal;
			const done = () => {
				clearTimeout(timer);
				signal.removeEventListener('abort', done);
				resolve();
			};
			const timer = setTimeout(
				done,
				Math.max(0, Math.min(seconds, Math.max(0, a.deadline - performance.now()) / 1000)) * 1000
			);
			signal.addEventListener('abort', done, { once: true });
			if (signal.aborted) done();
		});
	}
}
