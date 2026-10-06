import { writable } from 'svelte/store';
import type { ApprovalReceipt, ApprovalResult, Conflict, Preview, Proposal } from './contract';
import type { ApprovalJournal, ApprovalScope, PendingApproval, GovernanceAPI } from './api';

function record(value: unknown, keys: string[]): value is Record<string, unknown> {
	return (
		typeof value === 'object' &&
		value !== null &&
		!Array.isArray(value) &&
		Object.keys(value).length === keys.length &&
		keys.every((key) => Object.hasOwn(value, key))
	);
}
const strings = (value: unknown): value is string[] =>
	Array.isArray(value) && value.every((item) => typeof item === 'string');
const oneOf = (value: unknown, options: string[]) =>
	typeof value === 'string' && options.includes(value);

// Defensive settlement guard at the injected, typed API seam. This cannot
// authenticate a receipt or validate HTTP status/body pairs; the core adapter
// must do both before it can be enabled. Unknown envelopes never settle a key.
function approvalResult(value: unknown): value is ApprovalResult {
	if (record(value, ['kind']) && value.kind === 'purged') return true;
	if (record(value, ['kind', 'code']) && value.kind === 'transport_error')
		return oneOf(value.code, ['offline', 'indeterminate']);
	if (record(value, ['kind', 'code', 'resolution', 'conflicts']) && value.kind === 'error')
		return (
			oneOf(value.code, [
				'proposal_changed',
				'revision_changed',
				'history_unavailable',
				'validation_failed',
				'permission_denied',
				'unavailable',
				'expired_preview',
				'idempotency_conflict'
			]) &&
			oneOf(value.resolution, ['unresolved', 'not_committed']) &&
			Array.isArray(value.conflicts) &&
			value.conflicts.every(
				(conflict) =>
					record(conflict, ['code', 'column', 'eventIds', 'message']) &&
					oneOf(conflict.code, [
						'later_column_change',
						'history_unavailable',
						'revision_changed',
						'validation_failed',
						'proposal_changed',
						'unavailable'
					]) &&
					(conflict.column === null || typeof conflict.column === 'string') &&
					strings(conflict.eventIds) &&
					typeof conflict.message === 'string'
			)
		);
	if (!record(value, ['kind', 'value']) || value.kind !== 'success') return false;
	const receipt = value.value;
	return (
		record(receipt, [
			'operationId',
			'proposalId',
			'proposalVersion',
			'target',
			'revision',
			'historyEventIds',
			'approvedBy',
			'committedAt'
		]) &&
		['operationId', 'proposalId', 'proposalVersion', 'committedAt'].every(
			(key) => typeof receipt[key] === 'string'
		) &&
		record(receipt.target, ['table', 'rowId']) &&
		typeof receipt.target.table === 'string' &&
		typeof receipt.target.rowId === 'string' &&
		record(receipt.revision, ['updated_at', 'hub_at']) &&
		typeof receipt.revision.updated_at === 'string' &&
		(receipt.revision.hub_at === null || typeof receipt.revision.hub_at === 'string') &&
		strings(receipt.historyEventIds) &&
		record(receipt.approvedBy, ['principalId', 'kind']) &&
		typeof receipt.approvedBy.principalId === 'string' &&
		oneOf(receipt.approvedBy.kind, ['user', 'agent', 'service'])
	);
}

export interface ProposalReviewState {
	proposal: Proposal | null;
	preview: Preview | null;
	receipt: ApprovalReceipt | null;
	conflicts: Conflict[];
	error: string;
	busy: boolean;
	online: boolean;
	unresolved: boolean;
	purged: boolean;
	contentUnavailable: boolean;
}

export function createProposalReview(
	api: Pick<GovernanceAPI, 'previewProposal' | 'approveProposal'> | null,
	journal: ApprovalJournal | null,
	scope: ApprovalScope,
	onApplied: (receipt: ApprovalReceipt) => void = () => {}
) {
	let generation = 0;
	let contextGeneration = 0;
	let disposed = false;
	let pending: PendingApproval | null = null;
	let journalFailed = false;
	let approvalInFlight = false;
	const empty = (): ProposalReviewState => ({
		proposal: null,
		preview: null,
		receipt: null,
		conflicts: [],
		error: '',
		busy: false,
		online: false,
		unresolved: false,
		purged: false,
		contentUnavailable: false
	});
	let state = empty();
	const store = writable(state);
	const publish = () => store.set(state);
	const ready = (async () => {
		try {
			pending = (await journal?.load()) ?? null;
			if (
				pending &&
				(pending.scope.deploymentId !== scope.deploymentId ||
					pending.scope.sessionId !== scope.sessionId ||
					pending.scope.principalId !== scope.principalId)
			)
				throw new Error('Journal binding mismatch');
			state = { ...state, unresolved: pending !== null };
		} catch {
			journalFailed = true;
			state = {
				...state,
				error: 'Could not restore the pending approval. Approval is unavailable.'
			};
		}
		if (!disposed) publish();
	})();
	return {
		subscribe: store.subscribe,
		ready,
		setOnline(online: boolean) {
			if (!disposed) {
				state = { ...state, online };
				publish();
			}
		},
		async open(proposal: Proposal) {
			const started = contextGeneration;
			await ready;
			if (disposed || journalFailed || started !== contextGeneration) return;
			if (pending) {
				state = {
					...state,
					error: 'Resolve the pending approval before reviewing another proposal.'
				};
				publish();
				return;
			}
			const current = ++generation;
			state = { ...empty(), online: state.online, proposal, busy: !!api };
			publish();
			if (!api) {
				state = { ...state, error: 'Proposal review is unavailable from this connection.' };
				publish();
				return;
			}
			if (proposal.state !== 'pending') {
				state = { ...state, busy: false, error: 'This proposal is no longer pending.' };
				publish();
				return;
			}
			try {
				const result = await api.previewProposal({
					proposalId: proposal.id,
					expectedVersion: proposal.version
				});
				if (disposed || current !== generation) return;
				if (result.kind !== 'success') {
					state = {
						...state,
						proposal: result.kind === 'unavailable' ? null : state.proposal,
						contentUnavailable: result.kind === 'unavailable',
						busy: false,
						error:
							result.kind === 'unavailable'
								? 'This proposal is unavailable.'
								: 'Could not read this proposal. Retry online.'
					};
					publish();
					return;
				}
				const preview = result.value;
				if (
					preview.target.table !== proposal.target.table ||
					preview.target.rowId !== proposal.target.rowId
				)
					throw new Error('Preview target does not match this proposal.');
				state = { ...state, preview, busy: false };
			} catch (error) {
				if (disposed || current !== generation) return;
				state = {
					...state,
					busy: false,
					error: error instanceof Error ? error.message : 'Could not review this proposal.'
				};
			}
			publish();
		},
		async approve() {
			const started = contextGeneration;
			await ready;
			if (
				disposed ||
				state.busy ||
				approvalInFlight ||
				journalFailed ||
				started !== contextGeneration
			)
				return;
			if (!api || !journal || !state.online) {
				state = {
					...state,
					error:
						!api || !journal
							? 'Approval is unavailable from this connection.'
							: 'Connect online to approve or resolve an approval.'
				};
				publish();
				return;
			}
			const current = ++generation;
			approvalInFlight = true;
			try {
				if (!pending) {
					const { proposal, preview } = state;
					if (
						!proposal ||
						!preview?.previewToken ||
						preview.conflicts.length ||
						proposal.state !== 'pending'
					)
						return;
					pending = structuredClone({
						version: 1,
						scope,
						target: proposal.target,
						intent: proposal.intent,
						revision: preview.revision,
						changes: preview.changes,
						selectedEventIds: preview.selectedEventIds,
						request: {
							proposalId: proposal.id,
							expectedVersion: proposal.version,
							previewToken: preview.previewToken,
							idempotencyKey: crypto.randomUUID()
						}
					});
					state = { ...state, busy: true };
					publish();
					try {
						await journal.retain(structuredClone(pending));
					} catch {
						pending = null;
						journalFailed = true;
						if (disposed || current !== generation) return;
						state = {
							...state,
							busy: false,
							error:
								'Could not retain the approval request. Nothing was sent. Reopen to restore recovery storage.'
						};
						publish();
						return;
					}
				}
				if (disposed || current !== generation) return;
				const retained = structuredClone(pending);
				const sent = { ...retained.request };
				state = { ...state, busy: true, unresolved: true, error: '' };
				publish();
				let result: ApprovalResult;
				try {
					const received: unknown = await api.approveProposal(sent);
					result = approvalResult(received)
						? received
						: { kind: 'transport_error', code: 'indeterminate' };
					if (
						result.kind === 'success' &&
						(result.value.proposalId !== retained.request.proposalId ||
							result.value.proposalVersion !== retained.request.expectedVersion ||
							result.value.target.table !== retained.target.table ||
							result.value.target.rowId !== retained.target.rowId)
					)
						result = { kind: 'transport_error', code: 'indeterminate' };
				} catch {
					result = { kind: 'transport_error', code: 'indeterminate' };
				}
				// Only a terminal receipt settles the original request, even after unmount.
				// A rejection of this retry says nothing about an earlier dispatch.
				if (
					result.kind === 'success' ||
					result.kind === 'purged' ||
					(result.kind === 'error' && result.resolution === 'not_committed')
				) {
					try {
						await journal.resolve(retained);
						pending = null;
					} catch {
						journalFailed = true;
					}
					if (result.kind === 'success' && !disposed && current === generation) {
						try {
							onApplied(result.value);
						} catch {
							/* Applied receipt remains authoritative even if host refresh fails. */
						}
					}
				}
				if (disposed) return;
				if (current !== generation) {
					state = { ...state, unresolved: pending !== null };
					publish();
					return;
				}
				state = { ...state, busy: false, preview: null, unresolved: pending !== null };
				if (result.kind === 'success')
					state = { ...state, receipt: result.value, conflicts: [], contentUnavailable: false };
				else if (result.kind === 'purged')
					state = {
						...empty(),
						online: state.online,
						purged: true,
						contentUnavailable: true,
						unresolved: pending !== null
					};
				else if (result.kind === 'error')
					state = {
						...state,
						proposal:
							result.code === 'permission_denied' || result.code === 'unavailable'
								? null
								: state.proposal,
						contentUnavailable:
							result.code === 'permission_denied' || result.code === 'unavailable',
						conflicts: result.conflicts,
						error: result.code.replaceAll('_', ' ')
					};
				else
					state = {
						...state,
						error:
							result.code === 'offline'
								? 'Not sent. Connect online and retry the retained request.'
								: 'Approval outcome is unknown. Resolve the retained request before starting another.'
					};
				if (journalFailed)
					state = {
						...state,
						error:
							'The result arrived but its retained request could not be cleared. Reopen to reconcile it.'
					};
				publish();
			} finally {
				approvalInFlight = false;
			}
		},
		reset() {
			if (!disposed) {
				generation++;
				contextGeneration++;
				state = { ...empty(), online: state.online, unresolved: pending !== null };
				publish();
			}
		},
		dispose() {
			disposed = true;
			generation++;
			contextGeneration++;
		}
	};
}
