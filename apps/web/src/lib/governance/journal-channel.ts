import { CORE_CONTRACT_HASH } from 'iris-core/contract';
import type { JournalRequest, JournalReply, JournalTransport } from './journal-protocol';
export const JOURNAL_CHANNEL_PROTOCOL = 'iris-journal-channel-v1';
const unavailable = () =>
	new Error('Journal worker channel is unavailable; the request outcome may be uncertain.');
function object(value: unknown): value is Record<string, unknown> {
	return !!value && typeof value === 'object' && !Array.isArray(value);
}
function keys(value: Record<string, unknown>, expected: string[]) {
	return (
		Object.keys(value).length === expected.length &&
		expected.every((key) => Object.hasOwn(value, key))
	);
}
const identifier = (value: unknown): value is number =>
	typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
type Pending = {
	resolve(value: JournalReply): void;
	reject(error: unknown): void;
	timer: ReturnType<typeof setTimeout>;
	method: JournalRequest['method'] | 'shutdown';
};
/** An exclusively owned port to an owned dedicated key worker. The owner wires
 * worker error/page disposal to signal and MUST terminate the worker in terminate.
 * HTML MessagePort has no reliable peer-close notification. Silent loss is bounded
 * by request timeout; idle disposal relies on this explicit owner lifecycle.
 * No retry: after loss a durable pending journal must resolve the uncertain outcome.
 */
export function createJournalChannel(
	port: MessagePort,
	options: { signal: AbortSignal; terminate(): void; timeoutMs?: number }
) {
	const timeout = options.timeoutMs ?? 15000;
	if (!Number.isSafeInteger(timeout) || timeout < 1 || timeout > 30000)
		throw new Error('Invalid journal channel timeout.');
	let state: 'open' | 'closing' | 'stopped' = 'open',
		nextId = 0,
		closing: Promise<void> | undefined,
		cleanupError: unknown;
	const pending = new Map<number, Pending>();
	function stop(reason: Error) {
		if (state === 'stopped') return;
		state = 'stopped';
		port.removeEventListener('message', message);
		port.removeEventListener('messageerror', lost);
		options.signal.removeEventListener('abort', lost);
		port.close();
		try {
			options.terminate();
		} catch (error) {
			cleanupError = error;
		}
		for (const entry of pending.values()) {
			clearTimeout(entry.timer);
			entry.reject(reason);
		}
		pending.clear();
	}
	function lost() {
		stop(unavailable());
	}
	function message(event: MessageEvent) {
		const frame: unknown = event.data;
		if (
			!object(frame) ||
			frame.protocol !== JOURNAL_CHANNEL_PROTOCOL ||
			frame.contractHash !== CORE_CONTRACT_HASH
		) {
			lost();
			return;
		}
		if (frame.type === 'closed' && keys(frame, ['protocol', 'contractHash', 'type'])) {
			lost();
			return;
		}
		if (
			!identifier(frame.id) ||
			typeof frame.ok !== 'boolean' ||
			!keys(
				frame,
				frame.ok
					? ['protocol', 'contractHash', 'id', 'ok', 'result']
					: ['protocol', 'contractHash', 'id', 'ok', 'error']
			) ||
			(!frame.ok && frame.error !== 'request-failed')
		) {
			lost();
			return;
		}
		const entry = pending.get(frame.id);
		if (!entry) {
			lost();
			return;
		}
		if (!frame.ok) {
			pending.delete(frame.id);
			clearTimeout(entry.timer);
			entry.reject(new Error('Journal worker request failed.'));
			if (entry.method === 'shutdown') lost();
			return;
		}
		const value = frame.result;
		const valid =
			entry.method === 'open'
				? typeof value === 'string' && value.length > 0 && value.length <= 128
				: entry.method === 'load'
					? value === null || object(value)
					: value === null;
		if (!valid) {
			lost();
			return;
		}
		pending.delete(frame.id);
		clearTimeout(entry.timer);
		if (entry.method === 'shutdown') {
			stop(unavailable());
			if (cleanupError !== undefined) {
				entry.reject(new Error('Journal worker termination failed.'));
				return;
			}
		}
		entry.resolve(value as JournalReply);
	}
	function send(request: JournalRequest | undefined): Promise<JournalReply> {
		if (state === 'stopped' || (state !== 'open' && request !== undefined))
			return Promise.reject(unavailable());
		if (nextId === Number.MAX_SAFE_INTEGER) {
			lost();
			return Promise.reject(unavailable());
		}
		const id = ++nextId;
		return new Promise((resolve, reject) => {
			const timer = setTimeout(lost, timeout);
			pending.set(id, { resolve, reject, timer, method: request?.method ?? 'shutdown' });
			try {
				port.postMessage(
					request === undefined
						? {
								protocol: JOURNAL_CHANNEL_PROTOCOL,
								contractHash: CORE_CONTRACT_HASH,
								id,
								type: 'shutdown'
							}
						: {
								protocol: JOURNAL_CHANNEL_PROTOCOL,
								contractHash: CORE_CONTRACT_HASH,
								id,
								type: 'request',
								request
							}
				);
			} catch {
				lost();
			}
		});
	}
	port.addEventListener('message', message);
	port.addEventListener('messageerror', lost);
	options.signal.addEventListener('abort', lost, { once: true });
	port.start();
	if (options.signal.aborted) lost();
	return {
		request: ((request: JournalRequest) => send(request)) as JournalTransport,
		close() {
			if (closing) return closing;
			if (state === 'stopped') return Promise.reject(unavailable());
			state = 'closing';
			closing = send(undefined).then(() => {});
			return closing;
		},
		get cleanupError() {
			return cleanupError;
		}
	};
}
/** Install ONLY on a port handed over by the owning worker, after the host has
 * bound its authenticated connection. Requests cannot install keys or identities.
 * Faults close the host immediately; graceful shutdown drains earlier FIFO work.
 * dispose must drain the owning resource before shutdown acknowledgement. On loss
 * it must also end the key worker; normal shutdown ends via the client terminator.
 */
export function serveJournalChannel(
	port: MessagePort,
	host: { request(input: unknown): Promise<JournalReply>; close(): void },
	options: { signal: AbortSignal; dispose(reason: 'shutdown' | 'loss'): void | Promise<void> }
) {
	let stopped = false,
		lastId = 0,
		queue = Promise.resolve(),
		closing: Promise<void> | undefined,
		cleanupError: unknown;
	function finish(reply?: (failed: boolean) => void): Promise<void> {
		if (stopped) return closing ?? Promise.resolve();
		stopped = true;
		port.removeEventListener('message', message);
		port.removeEventListener('messageerror', lost);
		options.signal.removeEventListener('abort', lost);
		closing = (async () => {
			const failures: unknown[] = [];
			try {
				host.close();
			} catch (error) {
				failures.push(error);
			}
			try {
				await options.dispose(reply ? 'shutdown' : 'loss');
			} catch (error) {
				failures.push(error);
			}
			try {
				if (reply) reply(failures.length > 0);
				else
					port.postMessage({
						protocol: JOURNAL_CHANNEL_PROTOCOL,
						contractHash: CORE_CONTRACT_HASH,
						type: 'closed'
					});
			} catch (error) {
				failures.push(error);
			} finally {
				port.close();
			}
			if (failures.length) {
				cleanupError = new AggregateError(failures, 'Journal worker disposal failed.');
				throw cleanupError;
			}
		})();
		return closing;
	}
	function lost() {
		void finish().catch(() => {});
	}
	function message(event: MessageEvent) {
		if (stopped) return;
		const frame: unknown = event.data;
		if (
			!object(frame) ||
			frame.protocol !== JOURNAL_CHANNEL_PROTOCOL ||
			frame.contractHash !== CORE_CONTRACT_HASH ||
			!identifier(frame.id) ||
			frame.id <= lastId ||
			(frame.type !== 'request' && frame.type !== 'shutdown') ||
			!keys(
				frame,
				frame.type === 'request'
					? ['protocol', 'contractHash', 'id', 'type', 'request']
					: ['protocol', 'contractHash', 'id', 'type']
			)
		) {
			lost();
			return;
		}
		lastId = frame.id;
		const id = frame.id;
		queue = queue
			.then(async () => {
				if (stopped) return;
				if (frame.type === 'shutdown') {
					await finish((failed) =>
						port.postMessage(
							failed
								? {
										protocol: JOURNAL_CHANNEL_PROTOCOL,
										contractHash: CORE_CONTRACT_HASH,
										id,
										ok: false,
										error: 'request-failed'
									}
								: {
										protocol: JOURNAL_CHANNEL_PROTOCOL,
										contractHash: CORE_CONTRACT_HASH,
										id,
										ok: true,
										result: null
									}
						)
					);
					return;
				}
				let result: JournalReply;
				try {
					result = await host.request(frame.request);
				} catch {
					if (!stopped)
						port.postMessage({
							protocol: JOURNAL_CHANNEL_PROTOCOL,
							contractHash: CORE_CONTRACT_HASH,
							id,
							ok: false,
							error: 'request-failed'
						});
					return;
				}
				if (!stopped)
					port.postMessage({
						protocol: JOURNAL_CHANNEL_PROTOCOL,
						contractHash: CORE_CONTRACT_HASH,
						id,
						ok: true,
						result
					});
			})
			.catch(lost);
	}
	port.addEventListener('message', message);
	port.addEventListener('messageerror', lost);
	options.signal.addEventListener('abort', lost, { once: true });
	port.start();
	if (options.signal.aborted) lost();
	return {
		close: () => finish(),
		get cleanupError() {
			return cleanupError;
		}
	};
}
