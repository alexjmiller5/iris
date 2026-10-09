<script lang="ts">
	import { onDestroy, tick } from 'svelte';
	import { IconChecklist, IconX } from '@tabler/icons-svelte';
	import { createHttpHub, createChangesetAPI, isChangesetCapability } from 'iris-core/client';
	import { sessionRequest, type HubConnection } from '../device-enrollment';
	import { openChangesetJournal } from './changeset-journal';
	import { createChangesetReview, type ChangesetReviewState } from './changeset-review';
	let { connection, canReview = false }: { connection: HubConnection | null; canReview?: boolean } =
		$props();
	let dialog: HTMLDialogElement,
		proposalId = $state(''),
		opening = $state(false),
		failure = $state('');
	let reviewState = $state<ChangesetReviewState>({
		proposal: null,
		preview: null,
		receipt: null,
		busy: false,
		unresolved: false,
		error: ''
	});
	let model = $state.raw<ReturnType<typeof createChangesetReview> | null>(null);
	let unsubscribe: (() => void) | null = null,
		abort: AbortController | null = null,
		generation = 0;
	const value = (v: unknown) =>
		v === undefined
			? 'Not present'
			: v === null
				? 'Empty'
				: typeof v === 'string'
					? v
					: JSON.stringify(v);
	const fields = (before: Record<string, unknown> | null, after: Record<string, unknown> | null) =>
		[...new Set([...Object.keys(before ?? {}), ...Object.keys(after ?? {})])].filter(
			(k) => JSON.stringify(before?.[k]) !== JSON.stringify(after?.[k])
		);
	function close() {
		generation++;
		abort?.abort();
		abort = null;
		unsubscribe?.();
		unsubscribe = null;
		const old = model;
		model = null;
		if (old) void old.dispose();
		opening = false;
	}
	onDestroy(close);
	$effect(() => {
		if (!canReview && model) {
			dialog.close();
			close();
		}
	});
	async function open() {
		if (!connection || !canReview || opening) return;
		close();
		failure = '';
		reviewState = {
			proposal: null,
			preview: null,
			receipt: null,
			busy: false,
			unresolved: false,
			error: ''
		};
		opening = true;
		const current = ++generation,
			controller = new AbortController();
		abort = controller;
		await tick();
		dialog.showModal();
		try {
			const captured = { ...connection },
				response = await sessionRequest(
					captured,
					'GET',
					AbortSignal.any([controller.signal, AbortSignal.timeout(15000)])
				);
			if (current !== generation) return;
			const record = (v: unknown): v is Record<string, unknown> =>
				v !== null && typeof v === 'object' && !Array.isArray(v);
			const data = response.data;
			const capability =
				record(data) && record(data.capabilities) ? data.capabilities.changesets : null;
			if (
				response.status !== 200 ||
				!isChangesetCapability(capability) ||
				capability.principal.kind !== 'user' ||
				!capability.authority.approve
			)
				throw new Error(
					'This connection does not support approving related changes. Connect with an enrolled user session.'
				);
			const hub = createHttpHub(captured.endpoint, captured.token, (url, init) =>
				fetch(url, {
					...init,
					signal: AbortSignal.any([controller.signal, AbortSignal.timeout(30000)])
				})
			);
			const api = createChangesetAPI(capability, hub.changesetPost);
			if (!api) throw new Error('Review is unavailable from this connection.');
			const scope = {
				endpoint: hub.endpoint,
				deploymentId: capability.deploymentId,
				sessionId: capability.sessionId,
				principalId: capability.principal.principalId
			};
			const journal = await openChangesetJournal(scope);
			if (current !== generation) {
				journal.close();
				return;
			}
			model = createChangesetReview(api, journal, scope);
			unsubscribe = model.subscribe((v) => (reviewState = v));
			await model.ready;
			if (current !== generation) return;
			proposalId = new URL(location.href).searchParams.get('proposal') ?? proposalId;
		} catch (e) {
			if (current === generation)
				failure = e instanceof Error ? e.message : 'Could not open review.';
		} finally {
			if (current === generation) opening = false;
		}
	}
</script>

<button
	disabled={!connection || !canReview}
	title={!canReview
		? 'Save or discard drafts and sync pending edits before review.'
		: 'Review related changes'}
	onclick={open}><IconChecklist size={17} /> Review changes</button
>
<dialog bind:this={dialog} onclose={close} aria-labelledby="changeset-title">
	<header>
		<div>
			<h2 id="changeset-title">Review related changes</h2>
			<p>Check the complete set before saving it together.</p>
		</div>
		<button aria-label="Close review" onclick={() => dialog.close()}><IconX size={20} /></button>
	</header>
	{#if opening}<p role="status">Checking your connection and saved approvals…</p>{/if}
	{#if failure}<p role="alert" class="failure">{failure}</p>{/if}
	{#if model}
		<form
			onsubmit={(event) => {
				event.preventDefault();
				void model?.open(proposalId.trim());
			}}
		>
			<label for="changeset-id">Proposal ID</label>
			<div class="load">
				<input
					id="changeset-id"
					bind:value={proposalId}
					autocomplete="off"
					disabled={reviewState.busy || reviewState.unresolved}
				/><button disabled={!proposalId.trim() || reviewState.busy || reviewState.unresolved}
					>Open review</button
				>
			</div>
		</form>
	{/if}
	{#if reviewState.error}<p role="alert" class="failure">{reviewState.error}</p>{/if}
	{#if reviewState.busy}<p role="status">Checking the complete review…</p>{/if}
	{#if reviewState.unresolved}<p class="notice" role="status">
			An earlier approval is still awaiting a confirmed result. Resolve that request before starting
			another.
		</p>{/if}
	{#if reviewState.receipt}<p role="status" class="saved">
			Saved all {reviewState.receipt.rows.length} changes. Sync the workspace to refresh your local records.
		</p>{/if}
	{#if reviewState.proposal}
		<p class="summary">{reviewState.proposal.changes.length} related changes</p>
		{#each reviewState.proposal.changes as change, i (`${change.table}:${change.id}`)}
			<section aria-label={`Change ${i + 1}`}>
				<h3>
					{change.table}
					<span
						>{change.kind === 'create'
							? 'New record'
							: change.kind === 'soft_delete'
								? 'Move to trash'
								: 'Edit record'}</span
					>
				</h3>
				<details><summary>Record identity</summary><code>{change.id}</code></details>
				<div class="table-scroll">
					<table>
						<thead><tr><th>Property</th><th>Before</th><th>After</th></tr></thead><tbody>
							{#each fields(change.before, change.after) as field}<tr
									><th scope="row">{field}</th><td>{value(change.before?.[field])}</td><td
										>{value(change.after?.[field])}</td
									></tr
								>{/each}
						</tbody>
					</table>
				</div>
			</section>
		{/each}
	{/if}
	{#if model && !reviewState.receipt && (reviewState.preview || reviewState.unresolved)}
		<footer>
			<p>
				{reviewState.unresolved
					? 'The same saved request will be checked again.'
					: 'This saves every displayed change in one operation.'}
			</p>
			<button class="approve" disabled={reviewState.busy} onclick={() => model?.approve()}
				>{reviewState.unresolved
					? 'Resolve previous approval'
					: `Approve ${reviewState.proposal?.changes.length ?? 0} changes`}</button
			>
		</footer>
	{/if}
</dialog>

<style>
	button,
	input {
		font: inherit;
		color: var(--color-ink);
		background: var(--color-paper);
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		min-height: 40px;
		padding: 0.45rem 0.7rem;
	}
	button {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: 0.5rem;
		cursor: pointer;
	}
	button:disabled,
	input:disabled {
		opacity: 0.5;
		cursor: default;
	}
	button:focus-visible,
	input:focus-visible {
		outline: 2px solid var(--color-accent);
		outline-offset: 2px;
	}
	dialog {
		width: min(850px, calc(100vw - 2rem));
		max-height: calc(100dvh - 2rem);
		margin: auto;
		padding: 1.5rem;
		background: var(--color-paper);
		color: var(--color-ink);
		border: 1px solid var(--color-rule);
		border-radius: 0.75rem;
		overflow: auto;
	}
	dialog::backdrop {
		background: #0007;
	}
	header {
		display: flex;
		justify-content: space-between;
		align-items: start;
		gap: 1rem;
	}
	h2 {
		margin: 0;
		font-size: 1.45rem;
		font-weight: 650;
	}
	p {
		line-height: 1.5;
	}
	header p,
	footer p {
		color: var(--color-muted);
		font-size: 0.9rem;
	}
	form {
		margin: 1rem 0;
	}
	label {
		display: block;
		font-size: 0.85rem;
		margin-bottom: 0.4rem;
	}
	.load {
		display: flex;
		gap: 0.5rem;
	}
	.load input {
		flex: 1;
		min-width: 0;
	}
	section {
		padding: 1rem 0;
		border-top: 1px solid var(--color-rule);
	}
	h3 {
		font-size: 1rem;
		margin: 0 0 0.5rem;
		overflow-wrap: anywhere;
	}
	h3 span {
		font-weight: 400;
		color: var(--color-muted);
		margin-left: 0.6rem;
	}
	details {
		font-size: 0.8rem;
		color: var(--color-muted);
		margin-bottom: 0.8rem;
	}
	code {
		overflow-wrap: anywhere;
	}
	.table-scroll {
		overflow-x: auto;
	}
	table {
		border-collapse: collapse;
		width: 100%;
		table-layout: fixed;
		font-size: 0.85rem;
	}
	td,
	th {
		text-align: left;
		vertical-align: top;
		padding: 0.65rem;
		border-bottom: 1px solid var(--color-rule);
		overflow-wrap: anywhere;
		white-space: pre-wrap;
	}
	th {
		font-weight: 600;
	}
	thead th {
		color: var(--color-muted);
	}
	tbody th {
		width: 24%;
	}
	.failure {
		color: var(--color-violation);
	}
	.notice {
		border-left: 3px solid var(--color-accent);
		padding: 0.6rem 1rem;
	}
	.summary {
		font-weight: 600;
	}
	.saved {
		font-weight: 600;
	}
	footer {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 1rem;
		border-top: 1px solid var(--color-rule);
		padding-top: 1rem;
	}
	.approve {
		background: var(--color-accent);
		color: var(--color-on-accent);
		border-color: var(--color-accent);
	}
	@media (max-width: 540px) {
		dialog {
			padding: 1rem;
		}
		.load,
		footer {
			flex-direction: column;
			align-items: stretch;
		}
		td,
		th {
			padding: 0.5rem 0.25rem;
		}
		h3 span {
			display: block;
			margin: 0.25rem 0;
		}
	}
</style>
