<script lang="ts">
	import {
		boardRows,
		calendarRows,
		displayName,
		type Row,
		type Property,
		type ViewPresentation
	} from 'iris-core/client';
	import { calendarMonth } from './calendar-month';
	import { calendarContext } from './calendar-context';
	import RecordCover from './RecordCover.svelte';
	import type { RetainedFileResolver } from './retained-files';
	import { IconGripVertical } from '@tabler/icons-svelte';
	let {
		presentation,
		rows,
		properties,
		display,
		timeZone,
		dayStartMinutes = 0,
		options = [],
		canMove = false,
		onmove,
		onopen,
		resolveFile
	}: {
		presentation: ViewPresentation;
		rows: Row[];
		properties: Property[];
		display: string | null;
		timeZone: string;
		dayStartMinutes?: number;
		options?: string[];
		canMove?: boolean;
		onmove: (row: Row, value: string | null) => Promise<void>;
		onopen: (id: string) => void;
		resolveFile?: RetainedFileResolver;
	} = $props();
	let month = $state('');
	$effect(() => {
		if (!month) month = calendarContext(timeZone, new Date(), dayStartMinutes).today.slice(0, 7);
	});
	let root: HTMLDivElement;
	let dragging = $state<string | null>(null),
		start = { x: 0, y: 0 };
	const byID = $derived(new Map(rows.map((row) => [String(row.id), row])));
	const label = (row: Row) => displayName(row, display);
	const layout = $derived.by(() => {
		try {
			if (presentation.kind === 'calendar' && presentation.dateColumn) {
				const days = calendarMonth(month, timeZone, dayStartMinutes);
				const result = calendarRows({
					rows,
					dateColumn: presentation.dateColumn,
					endDateColumn: presentation.endDateColumn,
					days
				});
				return { calendar: result, error: '' };
			}
			if (presentation.kind === 'board' && presentation.groupColumn) {
				const property = properties.find((p) => p.col === presentation.groupColumn);
				const result = boardRows({
					rows,
					column: presentation.groupColumn,
					options: [...(property?.options ?? []).map((o) => o.v), ...options]
				});
				return { board: result, error: '' };
			}
			return { error: '' };
		} catch (e) {
			return { error: e instanceof Error ? e.message : 'Cannot display this view.' };
		}
	});
	function startDrag(event: PointerEvent, id: string) {
		if (!canMove) return;
		dragging = id;
		start = { x: event.clientX, y: event.clientY };
		(event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
	}
	function drop(event: PointerEvent) {
		const id = dragging;
		dragging = null;
		if (!id || Math.hypot(event.clientX - start.x, event.clientY - start.y) < 6) return;
		const target = document
			.elementFromPoint(event.clientX, event.clientY)
			?.closest<HTMLElement>('[data-board-column]');
		if (!target || !root.contains(target)) return;
		const column = layout.board?.columns[Number(target.dataset.boardColumn)],
			row = byID.get(id);
		if (row && column) void onmove(row, column.value);
	}
</script>

<div bind:this={root} class="presentation">
	{#if layout.error}<p role="alert">{layout.error}</p>{/if}
	{#if presentation.kind === 'gallery'}
		<div class="gallery" aria-label="Gallery view">
			{#each rows as row (row.id as string)}
				<button
					class="card gallery-card"
					onclick={() => onopen(String(row.id))}
					aria-label={`Open ${label(row)}`}
				>
					{#if presentation.coverColumn}<RecordCover
							value={row[presentation.coverColumn]}
							label={label(row)}
							{resolveFile}
						/>{/if}
					<strong>{label(row)}</strong>
				</button>
			{/each}
		</div>
	{:else if layout.calendar}
		<label class="month"
			>Month <input type="month" bind:value={month} aria-label="Calendar month" /></label
		>
		<div class="calendar" aria-label="Calendar view">
			{#each ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'] as name}<span class="weekday"
					>{name}</span
				>{/each}
			{#each layout.calendar.days as day, index (day.date)}
				<section
					class="day"
					style:grid-column-start={((new Date(day.date + 'T00:00:00Z').getUTCDay() + 6) % 7) + 1}
					aria-label={day.date}
				>
					<time datetime={day.date}>{Number(day.date.slice(-2))}</time>
					{#each day.rowIds as id (id)}{@const row = byID.get(id)!}
						<button class="event" onclick={() => onopen(id)}>{label(row)}</button>
					{/each}
				</section>
			{/each}
		</div>
		{#if layout.calendar.undated.length}
			<details>
				<summary>Unscheduled or invalid dates ({layout.calendar.undated.length})</summary>
				{#each layout.calendar.undated as id}<button class="event" onclick={() => onopen(id)}
						>{label(byID.get(id)!)}</button
					>{/each}
			</details>
		{/if}
	{:else if layout.board}
		<div class="board" aria-label="Board view">
			{#each layout.board.columns as column, index (column.value)}
				<section
					class="column"
					data-board-column={index}
					aria-label={`Column ${column.value ?? 'No value'}`}
				>
					<h2>{column.value ?? 'No value'} <span>{column.rowIds.length}</span></h2>
					{#each column.rowIds as id (id)}{@const row = byID.get(id)!}
						<div class:dragging={dragging === id} class="card board-card">
							<div class="card-title">
								<button
									class="grip"
									aria-label={`Drag ${label(row)}`}
									disabled={!canMove}
									onpointerdown={(event) => startDrag(event, id)}
									onpointerup={drop}
									onpointercancel={() => (dragging = null)}><IconGripVertical size={16} /></button
								>
								<button class="record-title" onclick={() => onopen(id)}>{label(row)}</button>
							</div>
							<select
								aria-label={`Move ${label(row)}`}
								value={column.value ?? ''}
								disabled={!canMove}
								onchange={(event) => {
									const next = event.currentTarget.value || null;
									event.currentTarget.value = column.value ?? '';
									void onmove(row, next);
								}}
							>
								{#each layout.board.columns as choice}<option value={choice.value ?? ''}
										>{choice.value ?? 'No value'}</option
									>{/each}
							</select>
						</div>
					{/each}
				</section>
			{/each}
		</div>
	{/if}
	<p class="coverage">Showing loaded records. Load more below to include additional matches.</p>
</div>

<style>
	.gallery {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
		gap: 16px;
	}
	.card {
		border: 1px solid var(--color-rule);
		border-radius: 8px;
		background: var(--color-paper);
		color: var(--color-ink);
		overflow: hidden;
	}
	.gallery-card {
		display: block;
		padding: 0;
		text-align: left;
	}
	.gallery-card strong {
		display: block;
		padding: 14px;
	}
	.month {
		display: flex;
		align-items: center;
		gap: 12px;
		margin-bottom: 12px;
	}
	.month input {
		width: auto;
	}
	.calendar {
		display: grid;
		grid-template-columns: repeat(7, minmax(0, 1fr));
		border: 1px solid var(--color-rule);
	}
	.weekday {
		padding: 8px;
		font-size: 0.8rem;
		text-align: center;
		color: var(--color-muted);
	}
	.day {
		min-height: 110px;
		border-top: 1px solid var(--color-rule);
		border-right: 1px solid var(--color-rule);
		padding: 6px;
		min-width: 0;
	}
	time {
		font-size: 0.8rem;
		display: block;
		margin-bottom: 6px;
	}
	.event {
		display: block;
		max-width: 100%;
		font-size: 0.8rem;
		text-align: left;
		margin: 3px 0;
		padding: 5px 7px;
		overflow-wrap: anywhere;
	}
	.board {
		display: flex;
		gap: 16px;
		overflow-x: auto;
		align-items: stretch;
		padding-bottom: 12px;
	}
	.column {
		flex: 0 0 250px;
		background: var(--color-bone);
		padding: 10px;
		border-radius: 8px;
		min-height: 200px;
	}
	h2 {
		font-size: 0.9rem;
		margin: 0 0 12px;
		display: flex;
		justify-content: space-between;
	}
	h2 span,
	.coverage {
		color: var(--color-muted);
		font-size: 0.8rem;
	}
	.board-card {
		padding: 10px;
		margin-bottom: 10px;
	}
	.card-title {
		display: flex;
		align-items: center;
		gap: 6px;
		margin-bottom: 10px;
	}
	.record-title {
		background: transparent;
		color: inherit;
		text-align: left;
		padding: 4px;
		font-weight: 600;
	}
	.grip {
		touch-action: none;
		cursor: grab;
		background: transparent;
		color: inherit;
		padding: 4px;
	}
	.dragging {
		opacity: 0.5;
	}
	.board-card select {
		font-size: 0.8rem;
		width: 100%;
	}
	@media (max-width: 650px) {
		.calendar {
			min-width: 580px;
		}
		.presentation {
			overflow-x: auto;
		}
		.gallery {
			grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
		}
	}
</style>
