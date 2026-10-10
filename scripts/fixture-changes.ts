import { resolve } from 'node:path';
import type { Server, ServerWebSocket } from 'bun';

/** The hub's real ChangeSignal behind a CHANGES binding for synthetic hubs. The
 * Worker authorizes each upgrade; Bun holds the socket, since Bun has no
 * WebSocketPair to hand back with the 101. */
export async function fixtureChanges(source: string) {
	const { ChangeSignal } = await import(resolve(source, 'worker/src/changes.js'));
	(globalThis as any).WebSocketPair ??= class { 0 = {}; 1 = {}; };
	const sockets = new Set<ServerWebSocket<unknown>>();
	const kept = new Map<string, unknown>();
	const signal = new ChangeSignal({
		storage: { get: async (k: string) => kept.get(k), put: async (k: string, v: unknown) => void kept.set(k, v) },
		blockConcurrencyWhile: (fn: () => Promise<void>) => fn(),
		acceptWebSocket() {},
		getWebSockets: () => [...sockets]
	});
	return {
		CHANGES: {
			idFromName: (name: string) => name,
			get: () => ({ fetch: (url: string | Request, init?: RequestInit) => signal.fetch(url instanceof Request ? url : new Request(url, init)) })
		},
		/** Completes an upgrade the Worker answered with 101; passes anything else through. */
		upgrade(request: Request, response: Response, server: Server<unknown>) {
			if (response.status !== 101) return response;
			const protocol = response.headers.get('Sec-WebSocket-Protocol');
			// Bun refuses an empty headers object: native clients offer no subprotocol.
			return server.upgrade(request, protocol ? { headers: { 'Sec-WebSocket-Protocol': protocol } } : undefined)
				? undefined
				: new Response('upgrade failed', { status: 400 });
		},
		// The runtime answers keepalive pings without waking the object.
		websocket: {
			open: (ws: ServerWebSocket<unknown>) => void sockets.add(ws),
			close: (ws: ServerWebSocket<unknown>) => void sockets.delete(ws),
			message: (ws: ServerWebSocket<unknown>, message: string | Buffer) => { if (message === 'ping') ws.send('pong'); }
		}
	};
}
