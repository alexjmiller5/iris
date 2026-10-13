<script lang="ts">
	import { onDestroy, untrack } from 'svelte';
	import type { SkippedTableDetail } from 'iris-core/client';
	import BreakName from './BreakName.svelte';
	import { focusReturn } from './popover';
	import {
		applyDownload,
		downloadChoices,
		skippedSize,
		type DownloadPrefs
	} from './skipped-tables';

	let {
		detail,
		prefs,
		onapprove,
		ondismiss
	}: {
		detail: SkippedTableDetail;
		prefs: DownloadPrefs;
		onapprove(next: DownloadPrefs): void;
		ondismiss(hide: boolean): void;
	} = $props();

	const choices = untrack(() => downloadChoices(detail, prefs));
	const limitChoice = choices.find((c) => c.kind === 'limit');
	let kind = $state<'include' | 'limit'>('include');
	let limit = $state(limitChoice?.kind === 'limit' ? limitChoice.maxRows : 0);
	let hide = $state(false);
	const minimum = limitChoice?.kind === 'limit' ? limitChoice.maxRows : 0;
	const valid = $derived(kind === 'include' || (Number.isSafeInteger(limit) && limit >= minimum));

	let dialog: HTMLDialogElement;
	onDestroy(focusReturn());
	$effect(() => {
		dialog?.showModal();
	});
	function approve(event: SubmitEvent) {
		event.preventDefault();
		if (!valid) return;
		onapprove(
			applyDownload(
				kind === 'include' ? { kind } : { kind, maxRows: limit },
				detail.table,
				$state.snapshot(prefs)
			)
		);
	}
</script>

<dialog
	bind:this={dialog}
	class="download-prompt"
	aria-labelledby="download-prompt-title"
	aria-describedby="download-prompt-description"
	oncancel={(event) => {
		event.preventDefault();
		ondismiss(hide);
	}}
>
	<form onsubmit={approve}>
		<header>
			<p class="eyebrow"><BreakName name={detail.table} /></p>
			<h2 id="download-prompt-title">Not synced on this device</h2>
		</header>
		<p id="download-prompt-description">
			Its records here are read-only and may be incomplete. Download it to edit them.
			{#if detail.waitingEdits}
				{detail.waitingEdits === 1
					? '1 earlier edit uploads'
					: `${detail.waitingEdits} earlier edits upload`}
				once it syncs.
			{/if}
		</p>
		<p class="size">{skippedSize(detail)}</p>
		<fieldset>
			<legend>Suggested setting</legend>
			<label class="choice">
				<input type="radio" name="download-choice" value="include" bind:group={kind} />
				<span>
					<span>Download this table on this device</span>
					<small>Syncs it whatever its size.</small>
				</span>
			</label>
			{#if limitChoice}
				<label class="choice">
					<input type="radio" name="download-choice" value="limit" bind:group={kind} />
					<span>
						<span>Raise the automatic row limit</span>
						<small>Tables up to this many rows sync, including others.</small>
					</span>
				</label>
				{#if kind === 'limit'}
					<label class="limit">
						<span>Row limit</span>
						<input
							type="number"
							min={minimum}
							step="1"
							bind:value={limit}
							aria-describedby="download-limit-hint"
						/>
					</label>
					<small id="download-limit-hint" class:invalid={!valid}
						>At least {minimum.toLocaleString('en-US')} to include this table.</small
					>
				{/if}
			{/if}
		</fieldset>
		<label class="hide">
			<input type="checkbox" bind:checked={hide} />
			<span>Don't show this again for this table</span>
		</label>
		<footer>
			<button type="button" class="secondary" onclick={() => ondismiss(hide)}>Not now</button>
			<button type="submit" disabled={!valid}>Download</button>
		</footer>
	</form>
</dialog>

<style>
	dialog {
		margin: auto;
		width: min(30rem, calc(100vw - 32px));
		max-height: 90vh;
		padding: 0;
		border: 1px solid var(--color-rule);
		border-radius: 0.5rem;
		background: var(--color-paper);
		color: var(--color-ink);
	}
	dialog::backdrop {
		background: rgb(0 0 0 / 0.35);
	}
	form {
		display: grid;
		gap: 0.9rem;
		padding: 1.25rem;
	}
	h2,
	p {
		margin: 0;
	}
	h2 {
		font-size: 1.25rem;
		font-weight: 650;
	}
	p {
		line-height: 1.5;
	}
	.eyebrow,
	small {
		color: var(--color-muted);
		font-size: 0.875rem;
	}
	.eyebrow {
		overflow-wrap: anywhere;
	}
	.size {
		font-variant-numeric: tabular-nums;
		font-weight: 600;
	}
	fieldset {
		display: grid;
		gap: 0.5rem;
		margin: 0;
		padding: 0.75rem;
		border: 1px solid var(--color-rule);
		border-radius: 6px;
	}
	legend {
		padding: 0 0.25rem;
		font-size: 0.875rem;
		font-weight: 600;
	}
	label {
		display: flex;
		align-items: start;
		gap: 0.6rem;
		cursor: pointer;
	}
	label > span {
		display: grid;
		gap: 0.1rem;
	}
	input[type='radio'],
	input[type='checkbox'] {
		flex: none;
		width: 1.05rem;
		height: 1.05rem;
		margin: 0.2rem 0 0;
		accent-color: var(--color-accent);
	}
	.limit {
		align-items: center;
		padding-left: 1.65rem;
		font-size: 0.875rem;
	}
	.limit input {
		width: 9rem;
		min-height: 34px;
		padding: 4px 8px;
		border: 1px solid var(--color-rule);
		border-radius: 6px;
		background: var(--color-paper);
		color: var(--color-ink);
		font: inherit;
		font-variant-numeric: tabular-nums;
	}
	#download-limit-hint {
		padding-left: 1.65rem;
	}
	.invalid {
		color: var(--color-violation);
	}
	footer {
		display: flex;
		justify-content: flex-end;
		gap: 0.5rem;
	}
	footer button {
		min-height: 38px;
		border: 1px solid transparent;
		border-radius: 6px;
		background: var(--color-accent);
		color: var(--color-on-accent);
		padding: 8px 13px;
		font: inherit;
		font-size: 13px;
		font-weight: 600;
		cursor: pointer;
	}
	footer .secondary {
		color: var(--color-ink);
		background: var(--color-paper);
		border-color: var(--color-rule);
	}
	footer button:disabled {
		opacity: 0.45;
		cursor: default;
	}
</style>
