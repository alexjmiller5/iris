<script lang="ts">
	import { onMount, tick } from 'svelte';
	import { IconX, IconArrowLeft, IconArrowUpRight } from '@tabler/icons-svelte';
	import type { Property, RemoteRowsPage, RemoteRowResult } from 'life-ui-core/client';
	import MarkdownEditor from './components/MarkdownEditor.svelte';
	import { createRemoteBrowser } from './remote-browser';
	let {
		table,
		properties,
		readPage,
		readRow,
		onclose
	}: {
		table: string;
		properties: Property[];
		readPage: (cursor?: string) => Promise<RemoteRowsPage>;
		readRow: (id: string) => Promise<RemoteRowResult>;
		onclose: () => void;
	} = $props();
	const id = $props.id();
	const model = createRemoteBrowser(
		(cursor) => readPage(cursor),
		(rowID) => readRow(rowID)
	);
	let dialog: HTMLDialogElement;
	let heading = $state<HTMLHeadingElement>();
	let recordID = $state('');
	let closed = false;
	const property = (column: string) => properties.find((p) => p.col === column);
	function close() {
		if (closed) return;
		closed = true;
		model.dispose();
		dialog.close();
		onclose();
	}
	async function open(rowID: string) {
		await model.open(rowID);
		await tick();
		if (!closed && $model.selected) heading?.focus();
	}
	onMount(() => {
		dialog.showModal();
		void model.refresh();
		return () => {
			closed = true;
			model.dispose();
			if (dialog.open) dialog.close();
		};
	});
</script>

<dialog
	bind:this={dialog}
	aria-labelledby={`${id}-title`}
	onclose={close}
	oncancel={(event) => {
		event.preventDefault();
		close();
	}}
>
	<header>
		<div>
			<p class="eyebrow">Read-only</p>
			<h2 id={`${id}-title`}>Online {table}</h2>
		</div>
		<button class="icon" aria-label="Close online browsing" onclick={close}
			><IconX size={20} /></button
		>
	</header>
	<p class="hint">
		Read from your hub without downloading this table. These records are available while this window
		is open.
	</p>
	{#if $model.selected}
		<button class="back" onclick={() => model.back()}
			><IconArrowLeft size={16} /> Back to online records</button
		>
		<h3 bind:this={heading} tabindex="-1">{$model.selected.label}</h3>
		{#if $model.selected.deleted}<p class="deleted">This record is in the trash.</p>{/if}
		<dl>
			{#each Object.entries($model.selected.record) as [column, value] (column)}
				<div class="field">
					<dt>{property(column)?.label || column}</dt>
					<dd>
						{#if property(column)?.type === 'markdown' && typeof value === 'string'}
							<MarkdownEditor
								id={`${id}-${column}`}
								label={String(property(column)?.label || column)}
								{value}
								disabled={true}
							/>
						{:else}{value === null ? 'Empty' : String(value)}{/if}
					</dd>
				</div>
			{/each}
		</dl>
	{:else}
		<div class="toolbar">
			<form
				onsubmit={(event) => {
					event.preventDefault();
					void open(recordID);
				}}
			>
				<label for={`${id}-lookup`}>Record ID</label>
				<div class="lookup">
					<input
						id={`${id}-lookup`}
						bind:value={recordID}
						autocomplete="off"
						placeholder="Exact ID"
					/><button disabled={$model.loading || !recordID} type="submit">Find ID</button>
				</div>
			</form>
		</div>
		<p role="status">
			{$model.loading ? 'Loading online records…' : `${$model.rows.length} records loaded`}
		</p>
		<div class="rows" aria-label="Online records">
			{#each $model.rows as row (String(row.record.id))}
				<button
					class="row"
					disabled={$model.loading}
					aria-label={row.label}
					onclick={() => open(String(row.record.id))}
				>
					<span
						><strong>{row.label}</strong><small
							>{String(row.record.id)}{row.deleted ? ' · In trash' : ''}</small
						></span
					><IconArrowUpRight size={17} />
				</button>
			{/each}
		</div>
		{#if $model.nextCursor !== null}<button
				class="more"
				disabled={$model.loading}
				onclick={() => model.more()}>Load more</button
			>{/if}
	{/if}
	{#if $model.error}<p class="failure" role="alert">{$model.error}</p>{/if}
	<p class="hint footer">
		Changes on other devices may appear between pages. To edit these records, include this table and
		sync.
	</p>
</dialog>

<style>
	dialog {
		width: min(740px, calc(100vw - 2rem));
		max-height: calc(100dvh - 2rem);
		margin: auto;
		padding: 1.5rem;
		color: var(--color-ink);
		background: var(--color-paper);
		border: 1px solid var(--color-rule);
		border-radius: 0.75rem;
		overflow-y: auto;
		overflow-wrap: anywhere;
	}
	dialog::backdrop {
		background: #0007;
	}
	header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 1rem;
	}
	h2 {
		margin: 0;
		font-size: 1.5rem;
		font-weight: 650;
	}
	h3 {
		font-size: 1.3rem;
		margin: 1.25rem 0;
	}
	.eyebrow {
		font-size: 0.7rem;
		text-transform: uppercase;
		letter-spacing: 0.12em;
		color: var(--color-accent);
		margin: 0 0 0.3rem;
	}
	.hint,
	[role='status'],
	small {
		font-size: 0.85rem;
		line-height: 1.5;
		color: var(--color-muted);
	}
	.hint {
		margin: 1rem 0;
	}
	.footer {
		border-top: 1px solid var(--color-rule);
		padding-top: 1rem;
	}
	button,
	input {
		color: var(--color-ink);
		background: var(--color-paper);
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		padding: 0.5rem 0.75rem;
		min-height: 40px;
	}
	button {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: 0.4rem;
		cursor: pointer;
		flex-shrink: 0;
	}
	button:hover {
		background: var(--color-accent-soft);
	}
	button:disabled {
		opacity: 0.5;
		cursor: default;
	}
	.icon {
		padding: 0.5rem;
	}
	.toolbar {
		display: flex;
		gap: 1rem;
		align-items: end;
	}
	form {
		flex: 1;
		min-width: 0;
	}
	label {
		display: block;
		font-size: 0.8rem;
		margin-bottom: 0.35rem;
	}
	.lookup {
		display: flex;
		gap: 0.5rem;
	}
	input {
		width: 100%;
		min-width: 0;
	}
	.rows {
		max-height: 45dvh;
		overflow: auto;
		margin: 0.5rem -0.2rem;
		padding: 0.2rem;
	}
	.row {
		width: 100%;
		justify-content: space-between;
		text-align: left;
		border-color: transparent;
		padding: 0.8rem;
		gap: 0.75rem;
	}
	.row span {
		min-width: 0;
	}
	.row strong {
		font-weight: 600;
	}
	.row small {
		display: block;
		margin-top: 0.2rem;
	}
	.row :global(svg) {
		flex-shrink: 0;
	}
	.more {
		margin-top: 0.75rem;
	}
	dl {
		margin: 1rem 0;
	}
	.field {
		padding: 1rem 0;
		border-top: 1px solid var(--color-rule);
	}
	dt {
		font-size: 0.8rem;
		color: var(--color-muted);
		margin-bottom: 0.45rem;
	}
	dd {
		margin: 0;
		white-space: pre-wrap;
		min-width: 0;
	}
	.deleted,
	.failure {
		color: var(--color-violation);
		font-size: 0.9rem;
	}
	.back {
		margin-top: 0.5rem;
	}
	@media (max-width: 480px) {
		dialog {
			padding: 1rem;
		}
		.toolbar {
			flex-wrap: wrap;
		}
		form {
			flex-basis: 100%;
		}
	}
</style>
