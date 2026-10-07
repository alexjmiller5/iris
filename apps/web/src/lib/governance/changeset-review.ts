import { writable } from 'svelte/store';
import type { ChangesetAPI } from 'life-ui-core/client';
import type { ChangesetProposal, ChangesetPreview, ChangesetApproval } from 'life-ui-core/contract';
import type { ChangesetJournal, ChangesetScope, PendingChangeset } from './changeset-journal';
import { decodeChangesetApproval } from './changeset-journal';
export interface ChangesetReviewState {
	proposal: ChangesetProposal | null;
	preview: ChangesetPreview | null;
	receipt: ChangesetApproval | null;
	busy: boolean;
	unresolved: boolean;
	error: string;
}
export function createChangesetReview(
	api: Pick<ChangesetAPI, 'getProposal' | 'previewProposal' | 'approveProposal'>,
	journal: ChangesetJournal,
	scope: ChangesetScope,
	newKey = () => crypto.randomUUID()
) {
	scope = { ...scope };
	let state: ChangesetReviewState = {
		proposal: null,
		preview: null,
		receipt: null,
		busy: true,
		unresolved: false,
		error: ''
	};
	const store = writable(state);
	let disposed = false,
		failed = false,
		generation = 0,
		pending: PendingChangeset | null = null,
		inflight: Promise<void> | null = null;
	const publish = () => {
		if (!disposed) store.set(state);
	};
	const ready = (async () => {
		try {
			const loaded = await journal.load();
			if (loaded) pending = decodeChangesetApproval(JSON.stringify(loaded), scope);
			state = { ...state, proposal: pending?.proposal ?? null, unresolved: pending !== null };
		} catch {
			failed = true;
			state = {
				...state,
				error: 'Could not restore the retained approval. Reopen this review to retry.'
			};
		}
		state = { ...state, busy: false };
		publish();
	})();
	async function open(id: string) {
		await ready;
		if (disposed || failed || inflight || pending) return;
		const request = ++generation;
		state = { ...state, busy: true, error: '', proposal: null, preview: null, receipt: null };
		publish();
		try {
			const result = await api.getProposal({ proposalId: id });
			if (disposed || request !== generation) return;
			if (result.kind !== 'success') {
				state = {
					...state,
					busy: false,
					error: 'This proposal is unavailable. Check the connection and try again.'
				};
				publish();
				return;
			}
			const proposal = structuredClone(result.value);
			state = { ...state, proposal };
			if (proposal.state !== 'pending') {
				state = { ...state, busy: false, error: 'This proposal has already been resolved.' };
				publish();
				return;
			}
			const preview = await api.previewProposal(
				{ proposalId: proposal.id, expectedVersion: proposal.version },
				proposal
			);
			if (disposed || request !== generation) return;
			state = {
				...state,
				busy: false,
				preview: preview.kind === 'success' ? structuredClone(preview.value) : null,
				error:
					preview.kind === 'success'
						? ''
						: 'The records changed or the preview is unavailable. Prepare a fresh proposal.'
			};
		} catch {
			if (disposed || request !== generation) return;
			state = { ...state, busy: false, error: 'Could not load this review. Try again online.' };
		}
		publish();
	}
	async function send() {
		try {
			if (!pending) {
				if (
					!state.proposal ||
					!state.preview ||
					Date.parse(state.preview.expiresAt) <= Date.now()
				) {
					state = { ...state, error: 'Refresh this review before approving.' };
					publish();
					return;
				}
				const entry: PendingChangeset = {
					version: 1,
					scope: { ...scope },
					proposal: structuredClone(state.proposal),
					request: {
						proposalId: state.proposal.id,
						expectedVersion: state.proposal.version,
						previewToken: state.preview.previewToken,
						idempotencyKey: newKey()
					}
				};
				try {
					await journal.retain(entry);
					pending = entry;
				} catch {
					failed = true;
					state = {
						...state,
						error:
							'Could not retain the approval. Nothing was sent. Reopen to restore recovery storage.'
					};
					return;
				}
			}
			if (disposed) return;
			const retained = structuredClone(pending);
			state = { ...state, unresolved: true };
			publish();
			let result;
			try {
				result = await api.approveProposal(retained.request, retained.proposal);
			} catch {
				result = { kind: 'transport_error' as const, code: 'indeterminate' as const };
			}
			const terminal =
				result.kind === 'success' ||
				result.kind === 'purged' ||
				(result.kind === 'error' && result.resolution === 'not_committed');
			if (terminal) {
				try {
					await journal.resolve(retained);
					pending = null;
				} catch {
					failed = true;
				}
			}
			state = {
				...state,
				preview: null,
				unresolved: pending !== null,
				receipt: result.kind === 'success' ? result.value : null,
				error: failed
					? 'The result arrived but recovery storage could not be cleared. Reopen to reconcile it.'
					: result.kind === 'success'
						? ''
						: result.kind === 'purged'
							? 'This proposal was removed.'
							: result.kind === 'error' && result.resolution === 'not_committed'
								? 'Nothing was applied. Prepare a fresh proposal after checking the changed records.'
								: 'The outcome is unresolved. Retry the retained request before approving anything else.'
			};
			if (result.kind === 'purged') state = { ...state, proposal: null };
		} finally {
			state = { ...state, busy: false };
			publish();
		}
	}
	return {
		subscribe: store.subscribe,
		ready,
		open,
		async approve() {
			await ready;
			if (disposed || failed || inflight || state.busy) return;
			state = { ...state, busy: true, error: '' };
			publish();
			inflight = send();
			try {
				await inflight;
			} finally {
				inflight = null;
			}
		},
		async dispose() {
			disposed = true;
			generation++;
			await ready;
			await inflight;
			journal.close();
		}
	};
}
