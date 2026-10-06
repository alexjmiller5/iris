import { writable } from 'svelte/store';
import type { ApprovalReceipt, ApprovalResult, Conflict, Preview, Proposal } from './contract';
import type { ApprovalJournal, ApprovalScope, PendingApproval, GovernanceAPI } from './api';

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
					result = await api.approveProposal(sent);
				} catch {
					result = { kind: 'transport_error', code: 'indeterminate' };
				}
				// A completed request still resolves its durable journal after unmount.
				if (result.kind !== 'transport_error') {
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
				if (result.kind === 'success') state = { ...state, receipt: result.value };
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
