<script lang="ts">
	import { onDestroy } from 'svelte';
	import { serializeExport, type ExportSnapshot, type ExportFile } from './serialize';

	let {
		snapshot,
		disabled = false,
		selectedIds
	}: {
		snapshot: ExportSnapshot | null;
		disabled?: boolean;
		selectedIds?: readonly string[];
	} = $props();
	let expanded = $state(false);
	let disclosure: HTMLDetailsElement;
	let trigger: HTMLElement;
	let format = $state<'json' | 'csv'>('json');
	let error = $state('');
	let metadata = $state<ExportFile | null>(null);
	let exportedCount = $state(0);
	const downloads = new Map<string, ReturnType<typeof setTimeout>>();
	function download(file: ExportFile) {
		const url = URL.createObjectURL(new Blob([file.text], { type: file.mimeType }));
		const link = document.createElement('a');
		link.href = url;
		link.download = file.filename;
		document.body.appendChild(link);
		try {
			link.click();
		} finally {
			link.remove();
			downloads.set(
				url,
				setTimeout(() => {
					URL.revokeObjectURL(url);
					downloads.delete(url);
				}, 1000)
			);
		}
	}
	function exportRows() {
		if (disabled || !snapshot) return;
		error = '';
		try {
			// Synchronous serialization freezes every file before the first download/navigation.
			const result = serializeExport(snapshot, { format, selectedIds });
			download(result.files[0]);
			exportedCount = result.rowCount;
			metadata = result.files[1] ?? null;
		} catch (cause) {
			error = cause instanceof Error ? cause.message : 'Export failed. Try again.';
		}
	}
	onDestroy(() => {
		for (const [url, timer] of downloads) {
			clearTimeout(timer);
			URL.revokeObjectURL(url);
		}
	});
</script>

<svelte:window
	onkeydown={(event) => {
		if (event.key === 'Escape' && expanded && disclosure.contains(event.target as Node)) {
			event.preventDefault();
			event.stopPropagation();
			expanded = false;
			trigger.focus();
		}
	}}
/>

<details class="export-control" bind:open={expanded} bind:this={disclosure}>
	<summary bind:this={trigger}>Export</summary>
	<div class="panel" role="group" aria-label="Export records">
		<div class="actions">
			<select aria-label="Export format" bind:value={format} disabled={disabled || !snapshot}>
				<option value="json">JSON (exact values)</option>
				<option value="csv">CSV (spreadsheet)</option>
			</select>
			<button type="button" disabled={disabled || !snapshot} onclick={exportRows}>
				{selectedIds === undefined ? 'Export loaded rows' : 'Export selection'}
			</button>
		</div>
		<p>
			{snapshot?.rows.length ?? 0} loaded {snapshot?.rows.length === 1 ? 'row' : 'rows'}. Table
			completeness and freshness unknown.
		</p>
		<p>Stored values only. Local edits may not be synced. Attached files are not included.</p>
		{#if format === 'csv'}<p>
				CSV can change types in spreadsheets. Download its metadata separately; use JSON for exact
				values.
			</p>{/if}
		{#if metadata}
			<button
				type="button"
				class="metadata"
				onclick={() => {
					try {
						download(metadata!);
					} catch {
						error = 'Metadata download failed. Try again.';
					}
				}}>Download CSV metadata</button
			>
			<span>For the last CSV: {exportedCount} {exportedCount === 1 ? 'row' : 'rows'}.</span>
		{/if}
		{#if error}<p role="alert">{error}</p>{/if}
	</div>
</details>

<style>
	.export-control {
		max-width: 100%;
		font-size: 0.8rem;
		color: var(--color-muted);
	}
	.export-control[open] {
		flex-basis: 100%;
	}
	summary {
		width: fit-content;
		cursor: pointer;
	}
	.panel {
		max-width: 32rem;
		margin-top: 8px;
		padding: 12px;
		border: 1px solid var(--color-rule);
		border-radius: 6px;
		background: var(--color-paper);
	}
	.actions {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		align-items: center;
	}
	summary,
	button,
	select {
		border: 1px solid var(--color-rule);
		border-radius: 6px;
		padding: 9px 10px;
		background: var(--color-paper);
		color: var(--color-ink);
		font: inherit;
	}
	button {
		cursor: pointer;
	}
	button:disabled,
	select:disabled {
		opacity: 0.5;
		cursor: default;
	}
	summary:focus-visible,
	button:focus-visible,
	select:focus-visible {
		outline: 2px solid var(--color-accent);
		outline-offset: 2px;
	}
	p {
		margin: 5px 0 0;
	}
	.metadata {
		margin: 8px 6px 0 0;
	}
	[role='alert'] {
		color: var(--color-ink);
		font-weight: 600;
	}
</style>
