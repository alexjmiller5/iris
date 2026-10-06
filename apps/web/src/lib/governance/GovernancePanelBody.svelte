<script lang="ts">
	import { onDestroy, onMount, untrack } from 'svelte';
	import type {
		ApprovalReceipt,
		HistoryEvent,
		Preview,
		Proposal,
		Target,
		ReadResult
	} from './contract';
	import type { ApprovalJournal, ApprovalScope, GovernanceAPI } from './api';
	import { createHistoryReview } from './history-review';
	import { createProposalReview } from './proposal-review';
	import { createReviewList } from './review-list';
	import { displayCell } from './value';
	import ChangeDiff from './ChangeDiff.svelte';
	// The wrapper remounts this body whenever the bound authority or target changes.
	let {
		api,
		scope,
		target,
		journal,
		online,
		onApplied
	}: {
		api: GovernanceAPI | null;
		scope: ApprovalScope;
		target: Target;
		journal: ApprovalJournal | null;
		online: boolean;
		onApplied: (receipt: ApprovalReceipt) => void;
	} = $props();
	const boundAPI = untrack(() => api);
	const boundTarget = untrack(() => ({ ...target }));
	const selection = createHistoryReview<ReadResult<Preview>>(async (eventIds) => {
		if (!boundAPI) throw new Error('History review is unavailable from this connection.');
		return boundAPI.previewChanges({
			target: boundTarget,
			intent: { kind: 'selected_inverse', eventIds }
		});
	});
	const approval = createProposalReview(
		boundAPI,
		untrack(() => journal),
		untrack(() => ({ ...scope })),
		(receipt) => onApplied(receipt)
	);
	$effect(() => approval.setOnline(online));
	function clearContent() {
		history.clear();
		inbox.clear();
		selection.reset();
	}
	const history = createReviewList<HistoryEvent>(
		async (cursor) => {
			if (!boundAPI) return { kind: 'unavailable' };
			const result = await boundAPI.historyEvents({
				target: boundTarget,
				...(cursor ? { cursor } : {})
			});
			return result.kind === 'success'
				? {
						kind: 'success',
						value: { items: result.value.events, nextCursor: result.value.nextCursor }
					}
				: result;
		},
		() => {
			clearContent();
			approval.reset();
		}
	);
	const inbox = createReviewList<Proposal>(
		async (cursor) => {
			if (!boundAPI) return { kind: 'unavailable' };
			const result = await boundAPI.listProposals({
				target: boundTarget,
				state: 'pending',
				...(cursor ? { cursor } : {})
			});
			return result.kind === 'success'
				? {
						kind: 'success',
						value: { items: result.value.proposals, nextCursor: result.value.nextCursor }
					}
				: result;
		},
		() => {
			clearContent();
			approval.reset();
		}
	);
	$effect(() => {
		if ($approval.contentUnavailable) clearContent();
	});
	$effect(() => {
		// Only responses accepted by the selection model may invalidate the current UI.
		if ($selection.preview?.kind === 'unavailable') {
			clearContent();
			approval.reset();
		}
	});
	onMount(() => {
		if (boundAPI) void history.more();
		if (boundAPI) void inbox.more();
	});
	onDestroy(() => {
		history.dispose();
		inbox.dispose();
		selection.dispose();
		approval.dispose();
	});
</script>

<section class="governance" aria-label="History and proposals">
	<h2>History and proposals</h2>
	{#if !api}
		<p role="status">This connection does not offer historical review or proposals.</p>
	{:else}
		<section aria-label="Historical changes">
			<h3>Historical changes</h3>
			<p class="muted">
				Review selected changes before reversing them. Other properties keep their current values.
			</p>
			{#each $history.items as event (event.id)}
				<article class="event">
					<label
						><input
							type="checkbox"
							checked={$selection.selected.includes(event.id)}
							disabled={!event.reversible ||
								$selection.loading ||
								$approval.busy ||
								$approval.unresolved}
							onchange={(e) => selection.select(event.id, e.currentTarget.checked)}
						/> <strong>{event.column}</strong></label
					>
					<p class="values">
						{displayCell(event.before)} <span class="muted">to</span>
						{displayCell(event.after)}
					</p>
					<p class="meta">
						{event.actor
							? `Verified ${event.actor.kind}: ${event.actor.principalId}`
							: 'Unknown actor'} · {event.occurredAt}
					</p>
					{#if event.claimedOrigin}<p class="meta">Reported source: {event.claimedOrigin}</p>{/if}
					{#if !event.reversible}<p class="muted">
							{event.unavailableReason ?? 'This change cannot be reversed.'}
						</p>{/if}
				</article>
			{/each}
			{#if $history.error}<p role="alert">{$history.error}</p>{/if}
			{#if $history.nextCursor !== null}<button
					disabled={$history.busy}
					onclick={() => history.more()}
					>{$history.error ? 'Retry history' : 'Load more history'}</button
				>{/if}
			{#if $history.busy}<p role="status">Loading history…</p>{/if}
			<button
				disabled={!$selection.selected.length ||
					$selection.loading ||
					$approval.busy ||
					$approval.unresolved}
				onclick={() => selection.review()}>Preview selected changes</button
			>
			{#if $selection.preview?.kind === 'transport_error'}<p role="alert">
					Could not preview selected history. Retry online.
				</p>{/if}
			{#if $selection.error}<p role="alert">{$selection.error}</p>{/if}
			{#if $selection.preview?.kind === 'success'}
				<ChangeDiff changes={$selection.preview.value.changes} />
				{#each $selection.preview.value.conflicts as conflict}<p role="alert">
						{conflict.message}
					</p>{/each}
			{/if}
		</section>
		<section aria-label="Pending proposals">
			<h3>Pending proposals</h3>
			{#each $inbox.items as proposal (proposal.id)}
				<article>
					<p>Proposed by {proposal.proposedBy.kind}: {proposal.proposedBy.principalId}</p>
					{#if proposal.claimedOrigin}<p class="meta">
							Reported source: {proposal.claimedOrigin}
						</p>{/if}
					<button
						disabled={$approval.busy || $approval.unresolved}
						onclick={() => approval.open(proposal)}>Review proposal</button
					>
				</article>
			{/each}
			{#if $inbox.error}<p role="alert">{$inbox.error}</p>{/if}
			{#if $inbox.nextCursor !== null}<button disabled={$inbox.busy} onclick={() => inbox.more()}
					>{$inbox.error ? 'Retry proposals' : 'Load more proposals'}</button
				>{/if}
			{#if $inbox.busy}<p role="status">Loading proposals…</p>{/if}
			{#if $approval.preview}
				<ChangeDiff changes={$approval.preview.changes} />
				{#each $approval.preview.conflicts as conflict}<p role="alert">{conflict.message}</p>{/each}
				<button
					disabled={!journal ||
						!online ||
						$approval.busy ||
						!$approval.preview.previewToken ||
						!!$approval.preview.conflicts.length ||
						$approval.unresolved}
					onclick={() => approval.approve()}>Approve online</button
				>
			{/if}
			{#if !journal}<p class="muted">
					Approval is unavailable until recovery storage is ready.
				</p>{/if}
			{#if !online}<p role="status">Connect online to approve.</p>{/if}
			{#if $approval.unresolved}<p role="status">
					A retained approval needs to be resolved before another can start.
				</p>
				<button disabled={!online || $approval.busy || !journal} onclick={() => approval.approve()}
					>Resolve retained approval</button
				>{/if}
			{#if $approval.busy}<p role="status">Reviewing proposal…</p>{/if}
			{#if $approval.error}<p role="alert">{$approval.error}</p>{/if}
			{#each $approval.conflicts as conflict}<p role="alert">{conflict.message}</p>{/each}
			{#if $approval.receipt}<p role="status">
					Applied by {$approval.receipt.approvedBy.kind}: {$approval.receipt.approvedBy.principalId}
				</p>{/if}
			{#if $approval.purged}<p role="status">
					The retained result has been removed. No historical content is available.
				</p>{/if}
		</section>
	{/if}
</section>

<style>
	.governance {
		color: var(--color-ink);
		background: var(--color-paper);
		font-size: 0.875rem;
		max-width: 64rem;
	}
	section section {
		padding: 1rem 0;
		border-top: 1px solid var(--color-rule);
	}
	h2 {
		font-size: 1.125rem;
		margin: 0 0 1rem;
	}
	h3 {
		font-size: 1rem;
		margin: 0 0 0.75rem;
	}
	article {
		padding: 0.75rem 0;
		border-bottom: 1px solid var(--color-rule);
	}
	label {
		display: flex;
		gap: 0.65rem;
		align-items: center;
		min-height: 2.75rem;
	}
	p {
		margin: 0.5rem 0;
		overflow-wrap: anywhere;
	}
	.values {
		white-space: pre-wrap;
	}
	.meta,
	.muted {
		color: var(--color-muted);
	}
	.meta {
		font-size: 0.8rem;
	}
	button {
		min-height: 2.75rem;
		padding: 0.5rem 0.75rem;
		margin: 0.5rem 0.5rem 0.5rem 0;
		border: 1px solid var(--color-rule);
		border-radius: 0.35rem;
		color: var(--color-ink);
		background: var(--color-paper);
		font: inherit;
		cursor: pointer;
	}
	button:disabled {
		opacity: 0.5;
		cursor: default;
	}
	button:focus-visible,
	input:focus-visible {
		outline: 2px solid var(--color-accent);
		outline-offset: 2px;
	}
	[role='alert'] {
		color: var(--color-violation);
	}
</style>
