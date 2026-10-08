<script lang="ts">
	import type { Property, Sort } from 'life-ui-core/client';
	import { IconArrowsSort, IconGripVertical, IconTrash, IconX } from '@tabler/icons-svelte';
	import { anchored } from './popover';
	import { editSort, moveItem } from './view-controls';

	// Sorts apply as they change; the parent saves the view after the popover closes.
	let {
		id,
		sorts,
		properties,
		disabled = false,
		anchor = $bindable(),
		onchange,
		ontoggle
	}: {
		/** Popover id, so a sort chip elsewhere can open the same menu. */
		id: string;
		sorts: Sort[];
		properties: Property[];
		disabled?: boolean;
		anchor?: HTMLElement;
		onchange: (sorts: Sort[]) => boolean | void;
		ontoggle?: (open: boolean) => void;
	} = $props();
	let button = $state<HTMLButtonElement>();
	let list = $state<HTMLOListElement>();
	let popover = $state<HTMLElement>();
	let dragging = $state<number | null>(null),
		target = $state<number | null>(null);
	const label = (column: string) => {
		const p = properties.find((p) => p.col === column);
		return p?.label || column;
	};
	const unused = $derived(properties.filter((p) => !sorts.some((s) => s.column === p.col)));
	const optionTypes = ['select', 'multi_select'];
	const typeOf = (column: string) => properties.find((p) => p.col === column)?.type ?? '';

	function startDrag(index: number, event: PointerEvent) {
		if (event.button !== 0 || !list) return;
		const handle = event.currentTarget as HTMLElement;
		const middles = [...list.children].map((row) => {
			const box = row.getBoundingClientRect();
			return box.top + box.height / 2;
		});
		const place = (y: number) => middles.filter((m, i) => i !== index && m < y).length;
		handle.setPointerCapture(event.pointerId);
		dragging = index;
		target = index;
		const move = (e: PointerEvent) => (target = place(e.clientY));
		const end = () => {
			handle.removeEventListener('pointermove', move);
			if (target !== null && target !== index) onchange(moveItem(sorts, index, target));
			dragging = target = null;
		};
		handle.addEventListener('pointermove', move);
		handle.addEventListener('pointerup', end, { once: true });
		handle.addEventListener('pointercancel', end, { once: true });
	}
	function keyMove(index: number, event: KeyboardEvent) {
		const delta = event.key === 'ArrowUp' ? -1 : event.key === 'ArrowDown' ? 1 : 0;
		const to = index + delta;
		if (!delta || to < 0 || to >= sorts.length) return;
		event.preventDefault();
		if (onchange(moveItem(sorts, index, to)) === false) return;
		requestAnimationFrame(() =>
			list?.querySelectorAll<HTMLElement>('.grip')[to]?.focus({ preventScroll: true })
		);
	}
</script>

<button
	bind:this={button}
	type="button"
	class="tool"
	class:active={sorts.length > 0}
	popovertarget={id}
	{disabled}
	aria-label={sorts.length ? `Sort, ${sorts.length} active` : 'Sort'}
	onclick={() => (anchor = button)}
	><IconArrowsSort size={16} aria-hidden="true" />Sort{#if sorts.length}<span class="count"
			>{sorts.length}</span
		>{/if}</button
>

<div
	{id}
	popover="auto"
	class="popover"
	role="dialog"
	aria-label="Sort"
	bind:this={popover}
	use:anchored={{
		anchor: () => anchor ?? button,
		ontoggle: (open) => {
			ontoggle?.(open);
			if (open) popover?.querySelector<HTMLElement>('select')?.focus();
		}
	}}
>
	{#if sorts.length}
		<ol bind:this={list} class="sorts" aria-label="Sort order">
			{#each sorts as sort, index (`${sort.column}:${index}`)}
				<li
					class:dragging={dragging === index}
					class:before={dragging !== null && target === index && target < dragging}
					class:after={dragging !== null && target === index && target > dragging}
				>
					<button
						type="button"
						class="grip"
						aria-label={`Reorder ${label(sort.column)} sort. Use the arrow keys to move it.`}
						onpointerdown={(e) => startDrag(index, e)}
						onkeydown={(e) => keyMove(index, e)}
						><IconGripVertical size={16} aria-hidden="true" /></button
					>
					<select
						aria-label={`Sort ${index + 1} property`}
						value={sort.column}
						onchange={(e) =>
							onchange(editSort(sorts, index, { column: e.currentTarget.value, mode: undefined }))}
					>
						{#each properties.filter((p) => p.col === sort.column || !sorts.some((s) => s.column === p.col)) as p (p.col)}
							<option value={p.col}>{label(p.col)}</option>
						{/each}
					</select>
					<select
						aria-label={`Sort ${index + 1} direction`}
						value={sort.direction}
						onchange={(e) =>
							onchange(
								editSort(sorts, index, { direction: e.currentTarget.value as Sort['direction'] })
							)}
					>
						<option value="asc">Ascending</option>
						<option value="desc">Descending</option>
					</select>
					{#if optionTypes.includes(typeOf(sort.column))}
						<select
							aria-label={`Sort ${index + 1} comparison`}
							value={sort.mode ?? 'value'}
							onchange={(e) =>
								onchange(editSort(sorts, index, { mode: e.currentTarget.value as Sort['mode'] }))}
						>
							<option value="value">By value</option>
							<option value="options">By option order</option>
						</select>
					{/if}
					<button
						type="button"
						class="icon"
						aria-label={`Remove ${label(sort.column)} sort`}
						onclick={() => onchange(sorts.filter((_, i) => i !== index))}
						><IconX size={16} aria-hidden="true" /></button
					>
				</li>
			{/each}
		</ol>
	{:else}
		<p class="hint">Records are in the order they were added.</p>
	{/if}
	<div class="foot">
		<select
			aria-label="Add sort"
			value=""
			disabled={!unused.length || sorts.length >= 16}
			onchange={(e) => {
				const column = e.currentTarget.value;
				e.currentTarget.value = '';
				if (column) onchange([...sorts, { column, direction: 'asc' }]);
			}}
		>
			<option value="">+ Add sort</option>
			{#each unused as p (p.col)}<option value={p.col}>{label(p.col)}</option>{/each}
		</select>
		{#if sorts.length}
			<button
				type="button"
				class="clear"
				onclick={() => {
					if (onchange([]) !== false) popover?.hidePopover();
				}}><IconTrash size={16} aria-hidden="true" />Delete sort</button
			>
		{/if}
	</div>
</div>

<style>
	.tool {
		display: inline-flex;
		align-items: center;
		gap: 0.375rem;
		min-height: 2.25rem;
		padding: 0 0.625rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
		font: inherit;
		font-size: 0.8125rem;
		cursor: pointer;
	}
	.tool:hover:not(:disabled) {
		background: var(--color-bone);
	}
	.tool.active,
	.tool.active:hover:not(:disabled) {
		border-color: var(--color-accent);
		background: var(--color-accent);
		color: var(--color-on-accent);
	}
	.tool.active:hover:not(:disabled) {
		background: color-mix(in srgb, var(--color-accent) 86%, var(--color-ink));
	}
	.tool:disabled {
		opacity: 0.5;
		cursor: default;
	}
	.count {
		min-width: 1.125rem;
		padding: 0 0.3125rem;
		border-radius: 999px;
		background: color-mix(in srgb, var(--color-on-accent) 22%, transparent);
		font-size: 0.6875rem;
		font-weight: 600;
		line-height: 1.125rem;
		text-align: center;
	}
	.popover {
		position: fixed;
		inset: auto;
		margin: 0;
		width: min(30rem, calc(100vw - 1rem));
		overflow-y: auto;
		padding: 0.5rem;
		border: 1px solid var(--color-rule);
		border-radius: 0.5rem;
		background: var(--color-paper);
		color: var(--color-ink);
		box-shadow:
			0 12px 32px -12px rgb(21 24 28 / 0.28),
			0 2px 6px rgb(21 24 28 / 0.08);
		font-size: 0.8125rem;
	}
	.sorts {
		display: grid;
		gap: 0.25rem;
		margin: 0 0 0.5rem;
		padding: 0;
		list-style: none;
	}
	li {
		display: flex;
		align-items: center;
		gap: 0.375rem;
		min-width: 0;
		padding: 0.125rem 0;
		border-radius: var(--radius-field);
	}
	li.dragging {
		background: var(--color-bone);
	}
	li.before {
		box-shadow: inset 0 2px 0 var(--color-accent);
	}
	li.after {
		box-shadow: inset 0 -2px 0 var(--color-accent);
	}
	select {
		flex: 1 1 0;
		min-width: 0;
		min-height: 2.25rem;
		padding: 0.375rem 0.5rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
		font: inherit;
	}
	.grip,
	.icon {
		display: inline-grid;
		place-items: center;
		flex: none;
		width: 2rem;
		height: 2.25rem;
		border: 0;
		border-radius: var(--radius-field);
		background: transparent;
		color: var(--color-muted);
		cursor: pointer;
	}
	.grip {
		width: 1.5rem;
		cursor: grab;
		touch-action: none;
	}
	.grip:hover,
	.icon:hover {
		background: var(--color-bone);
		color: var(--color-ink);
	}
	.foot {
		display: flex;
		gap: 0.5rem;
		flex-wrap: wrap;
	}
	.foot select {
		flex: 1 1 10rem;
	}
	.clear {
		display: inline-flex;
		align-items: center;
		gap: 0.375rem;
		min-height: 2.25rem;
		padding: 0 0.625rem;
		border: 0;
		border-radius: var(--radius-field);
		background: transparent;
		color: var(--color-muted);
		font: inherit;
		cursor: pointer;
	}
	.clear:hover {
		background: var(--color-bone);
		color: var(--color-violation);
	}
	.hint {
		margin: 0.25rem 0.25rem 0.5rem;
		color: var(--color-muted);
		font-size: 0.75rem;
	}
</style>
