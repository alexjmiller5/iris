import { isGovernanceCapability, isChangesetCapability } from 'iris-core/client';
import {
	decodePendingApproval,
	encodePendingApproval,
	type DurableJournal
} from './approval-journal';
import {
	decodeChangesetApproval,
	encodeChangesetApproval,
	changesetScopeKey
} from './changeset-journal';
import type { PendingApproval } from './api';
import type { PendingChangeset } from './changeset-journal';
import { createJournalProtection, openProtectedJournal } from './protected-journal';
import type { JournalKind, JournalReply } from './journal-protocol';
/** Supplied only by the unlocked worker resource. Capabilities must come from its
 * authenticated connection response, never a message sent by the page. */
export interface WorkerJournalResource {
	root: Uint8Array;
	workspace: string;
	generation: number;
	connection: { endpoint: string; capabilities: { governance?: unknown; changesets?: unknown } };
}
type Admission = {
	run<R>(
		operation: (resource: WorkerJournalResource, signal: AbortSignal) => Promise<R>
	): Promise<R>;
};
type Bound = {
	kind: JournalKind;
	identity: string;
	journal: DurableJournal<PendingApproval | PendingChangeset>;
};
const denied = () => new Error('Journal worker scope is unavailable or changed.');
function binding(resource: WorkerJournalResource, kind: JournalKind) {
	const connection = resource.connection;
	if (
		!connection ||
		typeof connection.endpoint !== 'string' ||
		!connection.endpoint.length ||
		!connection.capabilities ||
		!Number.isSafeInteger(resource.generation) ||
		resource.generation < 0
	)
		throw denied();
	const capability = connection.capabilities[kind];
	if (
		kind === 'governance' ? !isGovernanceCapability(capability) : !isChangesetCapability(capability)
	)
		throw denied();
	// Both canonical validators provide this common identity/authority contract.
	const approved = capability as {
		deploymentId: string;
		sessionId: string;
		principal: { kind: string; principalId: string };
		authority: { approve: boolean };
	};
	if (approved.principal.kind !== 'user' || !approved.authority.approve) throw denied();
	const scope = {
		deploymentId: approved.deploymentId,
		sessionId: approved.sessionId,
		principalId: approved.principal.principalId
	};
	const fullScope = { endpoint: connection.endpoint, ...scope };
	const storageScope = changesetScopeKey(fullScope);
	return {
		identity: JSON.stringify([resource.workspace, resource.generation, kind, storageScope]),
		storageScope,
		codec:
			kind === 'governance'
				? {
						encode: (entry: PendingApproval | PendingChangeset) =>
							encodePendingApproval(entry as PendingApproval, scope),
						decode: (raw: unknown) => decodePendingApproval(raw, scope)
					}
				: {
						encode: (entry: PendingApproval | PendingChangeset) =>
							encodeChangesetApproval(entry as PendingChangeset, fullScope),
						decode: (raw: unknown) => decodeChangesetApproval(raw, fullScope)
					}
	};
}
function checked(input: unknown): Record<string, unknown> {
	if (!input || typeof input !== 'object' || Array.isArray(input)) throw denied();
	const request = input as Record<string, unknown>;
	const keys =
		request.method === 'open'
			? ['method', 'kind']
			: request.method === 'retain' || request.method === 'resolve'
				? ['method', 'handle', 'entry']
				: ['method', 'handle'];
	if (
		Object.keys(request).length !== keys.length ||
		keys.some((key) => !Object.hasOwn(request, key))
	)
		throw denied();
	if (request.method === 'open') {
		if (request.kind !== 'governance' && request.kind !== 'changesets') throw denied();
	} else if (
		!['load', 'retain', 'resolve', 'close'].includes(String(request.method)) ||
		typeof request.handle !== 'string' ||
		!request.handle.length ||
		request.handle.length > 128
	)
		throw denied();
	return request;
}
/** Worker host only. The existing database worker is not wired to this factory yet. */
export function createWorkerJournalHost(options: {
	admission: Admission;
	openStore?: Parameters<typeof openProtectedJournal>[1]['openStore'];
}) {
	const handles = new Map<string, Bound>();
	let closed = false;
	const guard = (signal: AbortSignal) => {
		signal.throwIfAborted();
		if (closed) throw denied();
	};
	function assertBound(resource: WorkerJournalResource, bound: Bound, handle: string) {
		try {
			if (binding(resource, bound.kind).identity !== bound.identity) throw denied();
		} catch (error) {
			bound.journal.close();
			handles.delete(handle);
			throw error;
		}
	}
	return {
		async request(input: unknown): Promise<JournalReply> {
			const request = checked(input);
			if (request.method === 'close') {
				const handle = request.handle as string,
					bound = handles.get(handle);
				handles.delete(handle);
				bound?.journal.close();
				return null;
			}
			return options.admission.run(async (resource, signal) => {
				guard(signal);
				if (request.method === 'open') {
					const kind = request.kind as JournalKind,
						captured = binding(resource, kind);
					const protection = await createJournalProtection(
						resource.root,
						resource.workspace,
						resource.generation,
						kind,
						captured.storageScope
					);
					guard(signal);
					if (binding(resource, kind).identity !== captured.identity) throw denied();
					const journal = await openProtectedJournal(captured.codec, {
						protection,
						admission: options.admission,
						...(options.openStore ? { openStore: options.openStore } : {})
					});
					try {
						guard(signal);
						if (binding(resource, kind).identity !== captured.identity) throw denied();
						const handle = crypto.randomUUID();
						handles.set(handle, { kind, identity: captured.identity, journal });
						return handle;
					} catch (error) {
						journal.close();
						throw error;
					}
				}
				const handle = request.handle as string,
					bound = handles.get(handle);
				if (!bound) throw denied();
				assertBound(resource, bound, handle);
				let result: JournalReply = null;
				if (request.method === 'load') result = await bound.journal.load();
				else if (request.method === 'retain')
					await bound.journal.retain(request.entry as PendingApproval | PendingChangeset);
				else await bound.journal.resolve(request.entry as PendingApproval | PendingChangeset);
				guard(signal);
				assertBound(resource, bound, handle);
				return result;
			});
		},
		close() {
			closed = true;
			for (const bound of handles.values()) bound.journal.close();
			handles.clear();
		}
	};
}
