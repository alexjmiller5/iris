<script lang="ts">
	import { onDestroy } from 'svelte';
	import type { Property, Row } from 'life-ui-core/client';
	import type { BulkRecordResult } from './bulk-records';
	import FieldEditor from './FieldEditor.svelte';
	import { cellPatch } from './record-grid';
	let {
		selectedIds,
		properties,
		onrun,
		disabled = false,
		options = {},
		references = () => [],
		onsearch = () => {}
	}: {
		selectedIds: string[];
		properties: Property[];
		disabled?: boolean;
		options?: Record<string, string[]>;
		references?: (property: Property) => { id: string; label: string }[];
		onsearch?: (property: Property, query: string) => void;
		onrun: (
			ids: string[],
			patch: Row,
			signal: AbortSignal,
			progress: (results: BulkRecordResult[]) => void
		) => Promise<BulkRecordResult[]>;
	} = $props();
	let column = $state(''),
		raw = $state(''),
		clear = $state(false),
		running = $state(false),
		error = $state('');
	let operation: AbortController | undefined;
	let results = $state<BulkRecordResult[]>([]);
	let alive = true;
	const property = $derived(properties.find((p) => p.col === column));
	const counts = $derived({
		succeeded: results.filter((r) => r.status === 'succeeded').length,
		failed: results.filter((r) => r.status === 'failed').length,
		unattempted: results.filter((r) => r.status === 'unattempted').length
	});
	onDestroy(() => {
		alive = false;
		operation?.abort();
	});
	async function apply(trash = false) {
		if (disabled || running || !selectedIds.length || (!trash && !property)) return;
		const ids = [...selectedIds];
		let patch: Row;
		if (trash) patch = { deleted_at: true };
		else {
			const p = property!;
			const parsed = cellPatch(p, { cell: { rowId: '', column: p.col }, baseline: {}, raw });
			patch = {
				[p.col]: clear
					? null
					: ['number', 'int', 'bool'].includes(p.type ?? '')
						? parsed[p.col]
						: raw
			};
		}
		operation = new AbortController();
		running = true;
		error = '';
		results = ids.map((id) => ({ id, status: 'unattempted' }));
		try {
			const next = await onrun(ids, patch, operation.signal, (progress) => {
				if (alive) results = progress;
			});
			if (alive) results = next;
		} catch (cause) {
			if (alive) error = cause instanceof Error ? cause.message : 'Bulk changes failed.';
		} finally {
			if (alive) running = false;
		}
	}
</script>

<details class="bulk-actions">
	<summary>Selection ({selectedIds.length}){running ? ' · Saving…' : ''}</summary>
	<div role="group" aria-label="Selected row actions">
		<p>
			{selectedIds.length} selected. Each row is saved separately; failed rows stay unchanged. Cancel
			stops remaining rows.
		</p>
		<select
			aria-label="Bulk property"
			bind:value={column}
			disabled={disabled || running || !selectedIds.length}
			onchange={(event) => {
				column = event.currentTarget.value;
				raw = '';
				clear = false;
				const selected = properties.find((p) => p.col === column);
				if (selected) onsearch(selected, '');
			}}
		>
			<option value="">Choose a property</option>
			{#each properties as p}<option value={p.col}>{p.label || p.col}</option>{/each}
		</select>
		{#if property}
			<label
				><input type="checkbox" bind:checked={clear} disabled={disabled || running} />Clear value
				(null)</label
			>
			{#if !clear}<FieldEditor
					id="bulk-value"
					{property}
					value={raw}
					onchange={(value) => (raw = value)}
					disabled={disabled || running}
					options={options[property.col]}
					references={references(property)}
					onsearch={(query) => onsearch(property!, query)}
				/>{/if}
		{/if}
		<div class="actions">
			<button
				type="button"
				data-bulk-apply
				disabled={disabled || running || !selectedIds.length || !property}
				onclick={() => apply()}>Apply to selected</button
			>
			<button
				type="button"
				disabled={disabled || running || !selectedIds.length}
				onclick={() => apply(true)}>Move selected to trash</button
			>
			{#if running}<button type="button" onclick={() => operation?.abort()}>Cancel remaining</button
				>{/if}
		</div>
		{#if results.length}
			<p role="status">
				{counts.succeeded} succeeded · {counts.failed} failed · {counts.unattempted} unattempted
			</p>
			<details>
				<summary>Row results</summary>
				<ul>
					{#each results as result}<li>
							{result.id}: {result.status}{result.error ? ` - ${result.error}` : ''}
						</li>{/each}
				</ul>
			</details>
		{/if}
		{#if error}<p role="alert">{error}</p>{/if}
	</div>
</details>

<style>
	.bulk-actions {
		max-width: 100%;
		font-size: 0.85rem;
	}
	.bulk-actions[open] {
		flex-basis: 100%;
	}
	summary {
		cursor: pointer;
	}
	[role='group'] {
		max-width: 38rem;
		padding: 0.75rem;
		border: 1px solid var(--color-rule);
		border-radius: 0.4rem;
		margin-top: 0.5rem;
	}
	p {
		margin: 0.5rem 0;
	}
	.actions {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
		margin-top: 0.5rem;
	}
	button,
	select {
		padding: 0.5rem;
		border: 1px solid var(--color-rule);
		border-radius: 0.35rem;
		background: var(--color-paper);
		color: var(--color-ink);
	}
	button:disabled,
	select:disabled {
		opacity: 0.5;
	}
	label {
		display: block;
		margin: 0.5rem 0;
	}
	li {
		overflow-wrap: anywhere;
	}
</style>
