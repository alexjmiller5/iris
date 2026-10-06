<script lang="ts">
	import { onDestroy, tick } from 'svelte';
	import { Virtualizer } from 'virtua/svelte';
	import { IconPlus, IconCopy, IconTrash, IconRestore } from '@tabler/icons-svelte';
	import type { Property, Row, RowAction, ViewLayoutItem } from 'life-ui-core/client';
	import FieldEditor from './FieldEditor.svelte';
	import {
		createCellEditor,
		moveCell,
		type CellDraft,
		type CellKey,
		type CellState
	} from './record-grid';
	let {
		rows,
		properties,
		widths,
		busy,
		canCreate,
		canTrash = false,
		trash = false,
		format,
		canEdit,
		onbegin,
		oncommit,
		onopen,
		onnew,
		onduplicate,
		ontrash = async () => false,
		edit = $bindable(null),
		options = {},
		referenceOptions = () => [],
		onsearch = () => {},
		actions = [],
		actionLayout = undefined,
		canRunAction = false,
		onaction = async () => {}
	}: {
		rows: Row[];
		actions?: RowAction[];
		actionLayout?: ViewLayoutItem[];
		canRunAction?: boolean;
		onaction?: (actionId: string, row: Row) => Promise<void>;
		properties: Property[];
		widths: Record<string, number>;
		busy: boolean;
		canCreate: boolean;
		canTrash?: boolean;
		trash?: boolean;
		format(p: Property, value: unknown): string;
		canEdit(p: Property): boolean;
		onbegin(cell: CellKey): Promise<Row | false>;
		oncommit(edit: CellDraft): Promise<Row>;
		onopen(id: string): Promise<boolean>;
		onnew(): Promise<boolean>;
		onduplicate(id: string): Promise<boolean>;
		ontrash?(id: string): Promise<boolean>;
		edit?: CellDraft | null;
		options?: Record<string, string[]>;
		referenceOptions?(p: Property): { id: string; label: string }[];
		onsearch?(p: Property, query: string): void;
	} = $props();
	let root: HTMLDivElement, virtualizer: Virtualizer<Row>;
	let scrollRef: HTMLDivElement | undefined = $state();
	let cursor = $state<CellKey | null>(null);
	let cellState = $state<CellState>({ edit: null, phase: 'idle', error: '' });
	let alive = true;
	const controller = createCellEditor((next) => {
		if (alive) {
			cellState = next;
			edit = next.edit;
		}
	});
	onDestroy(() => {
		alive = false;
		controller.discard();
	});
	$effect(() => {
		if (!edit && cellState.edit && cellState.phase !== 'saving') controller.discard();
	});
	const columns = $derived(properties.map((p) => p.col));
	$effect(() => {
		if (
			cursor &&
			!edit &&
			(!columns.includes(cursor.column) || !rows.some((row) => String(row.id) === cursor?.rowId))
		)
			cursor = moveCell(rows, columns, cursor, 0, 0);
	});
	const gridItems = $derived.by(() => {
		const candidates = [
			...properties.map((p) => ({ kind: 'column' as const, id: p.col })),
			...actions.map((a) => ({ kind: 'action' as const, id: a.id }))
		];
		const ordered = (actionLayout ?? []).filter((i) =>
			candidates.some((c) => c.kind === i.kind && c.id === i.id)
		);
		return [
			...ordered,
			...candidates.filter((c) => !ordered.some((i) => c.kind === i.kind && c.id === i.id))
		];
	});
	const itemWidth = (item: ViewLayoutItem) =>
		item.kind === 'action'
			? 180
			: Number.isFinite(widths[item.id])
				? Math.min(800, Math.max(96, widths[item.id]))
				: item.id === properties[0]?.col && !actionLayout
					? 280
					: 180;
	const layout = $derived(gridItems.map((i) => `${itemWidth(i)}px`).join(' '));
	const totalWidth = $derived(gridItems.reduce((sum, i) => sum + itemWidth(i), 0));
	let runningAction = $state(false);
	async function runAction(id: string, row: Row) {
		if (busy || runningAction || !canRunAction) return;
		runningAction = true;
		try {
			if (await commit()) await onaction(id, row);
		} finally {
			runningAction = false;
		}
	}

	const activeIndex = $derived(
		rows.findIndex((row) => String(row.id) === (edit?.cell.rowId ?? cursor?.rowId))
	);
	const detached = $derived(
		edit &&
			(!columns.includes(edit.cell.column) ||
				!rows.some((row) => String(row.id) === edit?.cell.rowId))
	);
	const label = (p: Property) =>
		p.label || p.col.charAt(0).toUpperCase() + p.col.slice(1).replaceAll('_', ' ');
	function cellElement(cell: CellKey) {
		return root?.querySelector<HTMLElement>(
			`[data-row="${CSS.escape(cell.rowId)}"][data-column="${CSS.escape(cell.column)}"]`
		);
	}
	async function focus(cell: CellKey) {
		const available = moveCell(rows, columns, cell, 0, 0);
		if (!available) return;
		cell = available;
		cursor = cell;
		const index = rows.findIndex((row) => String(row.id) === cell.rowId);
		if (index >= 0) virtualizer?.scrollToIndex(index, { align: 'nearest' });
		await tick();
		if (alive) {
			const element = cellElement(cell);
			element?.focus();
			element?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
		}
	}
	async function commit() {
		const saved = await controller.commit(oncommit);
		if (!saved && cellState.phase === 'editing') {
			await tick();
			if (alive) focusEditor();
		}
		return saved;
	}
	function focusEditor() {
		root
			.querySelector<HTMLElement>(
				'[data-cell-editor] input, [data-cell-editor] select, [data-cell-editor] textarea, [data-cell-editor] [contenteditable="true"]'
			)
			?.focus();
	}
	async function choose(cell: CellKey) {
		if (busy || cellState.phase === 'saving') return;
		if (
			edit &&
			(edit.cell.rowId !== cell.rowId || edit.cell.column !== cell.column) &&
			!(await commit())
		)
			return;
		await focus(cell);
	}
	async function begin(cell: CellKey) {
		if (busy || cellState.phase === 'saving') return;
		const property = properties.find((p) => p.col === cell.column);
		if (!property || !canEdit(property)) return;
		if (edit && !(await commit())) return;
		cursor = cell;
		await controller.begin(cell, () => onbegin(cell));
		await tick();
		if (alive && edit?.cell.rowId === cell.rowId && edit.cell.column === cell.column) focusEditor();
	}
	async function open(id: string) {
		if (!busy && (await commit())) await onopen(id);
	}
	async function keyboard(event: KeyboardEvent, cell: CellKey) {
		if (event.defaultPrevented || event.isComposing || busy || cellState.phase === 'saving') return;
		const editing = !!edit;
		// Editors keep their normal arrows/Enter and may consume a key with
		// preventDefault; otherwise Escape/Tab use the same cell commit path.
		if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') {
			event.preventDefault();
			await open(cell.rowId);
			return;
		}
		if (editing) {
			if (event.key !== 'Escape' && event.key !== 'Tab') return;
			// After rejection, keep native focus traversal so Discard and Save are reachable.
			if (event.key === 'Tab' && cellState.error) return;
			event.preventDefault();
			const next =
				event.key === 'Tab'
					? moveCell(rows, columns, cell, event.shiftKey ? -1 : 1, 0, true)
					: cell;
			if (await commit()) {
				if (next) await focus(next);
				else root.querySelector<HTMLButtonElement>('[aria-label="New record at bottom"]')?.focus();
			}
			return;
		}
		if (event.key === 'Enter') {
			event.preventDefault();
			await begin(cell);
			return;
		}
		const direction = {
			ArrowLeft: [-1, 0],
			ArrowRight: [1, 0],
			ArrowUp: [0, -1],
			ArrowDown: [0, 1],
			Tab: [event.shiftKey ? -1 : 1, 0]
		}[event.key];
		if (!direction) return;
		const next = moveCell(rows, columns, cell, direction[0], direction[1], event.key === 'Tab');
		if (next) {
			event.preventDefault();
			await focus(next);
		}
	}
	async function discardCell() {
		const cell = edit?.cell;
		if (controller.discard() && cell) await focus(cell);
	}
</script>

{#snippet editor(property: Property, draft: CellDraft)}
	<div data-cell-editor class="cell-editor" role="group" aria-label={`Edit ${label(property)}`}>
		<FieldEditor
			id={`cell-${property.col}`}
			{property}
			value={draft.raw}
			onchange={controller.change}
			disabled={busy || cellState.phase === 'saving' || !canEdit(property)}
			options={options[property.col]}
			references={referenceOptions(property)}
			onsearch={(query) => onsearch(property, query)}
		/>
		{#if property.description}<small>{property.description}</small>{/if}
		{#if cellState.error}<p role="alert">{cellState.error}</p>{/if}
		<div class="edit-actions">
			<button
				type="button"
				disabled={busy || cellState.phase === 'saving' || !canEdit(property)}
				onclick={async () => {
					const cell = draft.cell;
					if (await commit()) await focus(cell);
				}}>Save cell</button
			><button type="button" disabled={busy || cellState.phase === 'saving'} onclick={discardCell}
				>Discard</button
			><small>{cellState.phase === 'saving' ? 'Saving…' : 'Esc saves'}</small>
		</div>
	</div>
{/snippet}
<div bind:this={root} class="record-grid">
	<div bind:this={scrollRef} class="grid-scroll">
		<table
			role="grid"
			aria-label="Records"
			aria-rowcount={rows.length + 1}
			aria-colcount={gridItems.length}
			style:width={`${totalWidth}px`}
		>
			<thead
				><tr style:grid-template-columns={layout}
					>{#each gridItems as item, index}<th role="columnheader" class:pinned={index === 0}
							>{item.kind === 'action'
								? actions.find((a) => a.id === item.id)?.label
								: item.id === properties[0]?.col && !actionLayout
									? 'Record'
									: label(properties.find((p) => p.col === item.id)!)}</th
						>{/each}</tr
				></thead
			>
			<Virtualizer
				{scrollRef}
				bind:this={virtualizer}
				data={rows}
				getKey={(row) => String(row.id)}
				as="tbody"
				item="tr"
				itemSize={44}
				ssrCount={5}
				startMargin={40}
				keepMounted={activeIndex < 0 ? [] : [activeIndex]}
				itemProps={({ index }) => ({
					role: 'row',
					'aria-rowindex': index + 2,
					style: { display: 'grid', 'grid-template-columns': layout, width: '100%' }
				})}
			>
				{#snippet children(row)}
					{#each gridItems as item, columnIndex (`${item.kind}:${item.id}`)}
						{#if item.kind === 'action'}
							{@const action = actions.find((a) => a.id === item.id)!}
							<td role="gridcell" class:pinned={columnIndex === 0}
								><button
									type="button"
									aria-label={action.label}
									disabled={busy || runningAction || !canRunAction || cellState.phase === 'saving'}
									onclick={() => runAction(action.id, row)}>{action.label}</button
								></td
							>
						{:else}
							{@const property = properties.find((p) => p.col === item.id)!}
							{@const cell = { rowId: String(row.id), column: property.col }}
							{@const active = edit?.cell.rowId === cell.rowId && edit.cell.column === cell.column}
							<td
								role="gridcell"
								data-row={cell.rowId}
								data-column={cell.column}
								aria-label={`${label(property)}: ${format(property, row[property.col])}`}
								aria-readonly={!canEdit(property)}
								tabindex={cursor
									? cursor.rowId === cell.rowId && cursor.column === cell.column
										? 0
										: -1
									: rows[0] === row && columnIndex === 0
										? 0
										: -1}
								class:pinned={columnIndex === 0}
								class:active
								class:cursor={cursor?.rowId === cell.rowId && cursor.column === cell.column}
								onclick={(event) => {
									if (
										!(event.target as HTMLElement).closest(
											'button,input,textarea,select,[contenteditable]'
										)
									)
										void choose(cell);
								}}
								ondblclick={(event) => {
									if (
										!(event.target as HTMLElement).closest(
											'button,input,textarea,select,[contenteditable]'
										)
									)
										void begin(cell);
								}}
								onkeydown={(event) => keyboard(event, cell)}
							>
								{#if active && edit}{@render editor(property, edit)}
								{:else if property.col === properties[0]?.col}<button
										class="record-link"
										tabindex="-1"
										onclick={() => open(cell.rowId)}
										>{format(property, row[property.col]) || cell.rowId}</button
									>
								{:else}<span class="cell-value">{format(property, row[property.col])}</span>{/if}
							</td>
						{/if}{/each}
				{/snippet}
			</Virtualizer>
		</table>
	</div>
	{#if detached && edit}
		{@const property = properties.find((p) => p.col === edit?.cell.column)}
		<div class="retained">
			<p>
				{property
					? 'This record is no longer in the visible page. Your cell draft is kept.'
					: 'This property is no longer available. Your cell draft is kept.'}
			</p>
			{#if property}{@render editor(property, edit)}{:else}<pre>{edit.raw}</pre>
				<button onclick={discardCell}>Discard</button>{/if}
		</div>
	{/if}
	{#if cellState.error && !edit}<p role="alert">{cellState.error}</p>{/if}
	{#if cellState.phase === 'loading'}<p role="status">Opening cell…</p>{/if}
	<div class="grid-actions">
		<button
			type="button"
			aria-label="New record at bottom"
			disabled={busy || !canCreate}
			onclick={() => onnew()}><IconPlus size={16} />New record</button
		><button
			type="button"
			disabled={busy || !canCreate || !cursor}
			onclick={() => cursor && onduplicate(cursor.rowId)}
			><IconCopy size={16} />Duplicate record</button
		>
		<button
			type="button"
			aria-label={trash ? 'Restore selected record' : 'Trash selected record'}
			disabled={busy || !canTrash || !cursor}
			onclick={() => cursor && ontrash(cursor.rowId)}
			>{#if trash}<IconRestore size={16} />Restore record{:else}<IconTrash size={16} />Move to trash{/if}</button
		>
	</div>
</div>

<style>
	.record-grid {
		min-width: 0;
		margin-top: 12px;
	}
	.grid-scroll {
		overflow: auto;
		max-height: min(60vh, 640px);
		min-height: 84px;
		border: 1px solid var(--color-rule);
		border-radius: 6px;
		overflow-anchor: none;
	}
	table {
		border-collapse: separate;
		border-spacing: 0;
		text-align: left;
	}
	thead {
		position: sticky;
		top: 0;
		z-index: 3;
		display: block;
		background: var(--color-bone);
	}
	thead tr {
		display: grid;
		height: 40px;
	}
	:global(.record-grid tbody) {
		display: block;
	}
	th,
	td {
		min-width: 0;
		padding: 10px 12px;
		border-bottom: 1px solid var(--color-rule);
		border-right: 1px solid var(--color-rule);
	}
	th {
		font-size: 12px;
		color: var(--color-muted);
		font-weight: 600;
	}
	td {
		min-height: 44px;
		font-size: 14px;
		background: var(--color-paper);
	}
	.pinned {
		position: sticky;
		left: 0;
		z-index: 1;
		background: var(--color-paper);
	}
	th.pinned {
		background: var(--color-bone);
	}
	.cursor {
		box-shadow: inset 0 0 0 2px var(--color-accent);
	}
	.active {
		padding: 8px;
		min-width: 0;
		z-index: 2;
	}
	.cell-value,
	.record-link {
		display: block;
		overflow: hidden;
		white-space: nowrap;
		text-overflow: ellipsis;
		max-width: 100%;
	}
	.record-link {
		color: var(--color-accent);
		background: transparent;
		border: 0;
		padding: 0;
		text-align: left;
		font: inherit;
		cursor: pointer;
	}
	.cell-editor {
		display: grid;
		gap: 6px;
	}
	.edit-actions,
	.grid-actions {
		display: flex;
		gap: 8px;
		flex-wrap: wrap;
		align-items: center;
	}
	.grid-actions {
		padding-top: 10px;
	}
	button {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		color: var(--color-ink);
		background: var(--color-paper);
		font: inherit;
		font-size: 13px;
		padding: 6px 8px;
		cursor: pointer;
	}
	button:disabled {
		opacity: 0.5;
		cursor: default;
	}
	small,
	p {
		font-size: 12px;
		color: var(--color-muted);
	}
	[role='alert'] {
		color: var(--color-violation);
		white-space: normal;
	}
	.retained {
		border: 1px solid var(--color-rule);
		padding: 12px;
		max-width: 560px;
	}
	pre {
		white-space: pre-wrap;
		overflow-wrap: anywhere;
	}
	@media (max-width: 540px) {
		.pinned {
			position: static;
		}
		.grid-scroll {
			max-height: 55vh;
		}
	}
</style>
