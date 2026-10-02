<script lang="ts">
	import { tick } from 'svelte';
	import {
		IconArrowLeft,
		IconArrowRight,
		IconChevronDown,
		IconColumns
	} from '@tabler/icons-svelte';
	import type { Property } from 'life-ui-core/client';
	import { visibleColumns, toggleColumn, moveColumn, changeWidth } from './column-settings';

	let {
		properties,
		columns,
		widths,
		onChange
	}: {
		/** Supply configurable properties only; the parent keeps Record visible and first. */
		properties: Property[];
		/** Explicit visible order, including an empty array for Record only. */
		columns: string[];
		widths: Record<string, number>;
		/** Emitted only after user edits. Hidden columns retain their remembered widths. */
		onChange: (columns: string[], widths: Record<string, number>) => void;
	} = $props();

	const id = $props.id();
	const available = $derived(new Map(properties.map((property) => [property.col, property])));
	const selected = $derived(visibleColumns(properties, columns));
	let message = $state('');
	const label = (property: Property) => property.label || property.col;

	function toggle(col: string, shown: boolean) {
		onChange(toggleColumn(selected, col, shown), { ...widths });
	}
	async function move(col: string, direction: -1 | 1, button: HTMLButtonElement) {
		const next = moveColumn(selected, col, direction);
		onChange(next, { ...widths });
		message = `${label(available.get(col)!)} moved to position ${next.indexOf(col) + 1} after Record.`;
		await tick();
		// A boundary move disables the pressed button. Keep keyboard focus on this column.
		if (button.disabled) {
			button
				.closest('[role="group"]')
				?.querySelector<HTMLButtonElement>('button:not(:disabled)')
				?.focus();
		}
	}
	function resize(property: Property, input: HTMLInputElement) {
		const next = input.validity.badInput ? null : changeWidth(widths, property.col, input.value);
		if (next) {
			onChange([...selected], next);
			message =
				next[property.col] === undefined
					? `${label(property)} width set to automatic.`
					: `${label(property)} width set to ${next[property.col]} pixels.`;
		} else {
			message = 'Enter a number from 96 to 800, or clear the width for automatic sizing.';
		}
		// Reflect clamping even when it produces the same value as the previous prop.
		input.value = String((next ?? widths)[property.col] ?? '');
	}
</script>

<details>
	<summary>
		<IconColumns size={18} aria-hidden="true" />
		Columns
		<span class="chevron"><IconChevronDown size={16} aria-hidden="true" /></span>
	</summary>
	<div class="panel">
		<p class="hint">Record stays visible and first.</p>
		<fieldset class="choices">
			<legend>Show properties</legend>
			{#each [...available.values()] as property (property.col)}
				<label class="choice">
					<input
						type="checkbox"
						aria-label={`Show ${label(property)}`}
						checked={selected.includes(property.col)}
						onchange={(event) => toggle(property.col, event.currentTarget.checked)}
					/>
					<span>{label(property)}</span>
				</label>
			{:else}
				<p class="hint">No additional properties.</p>
			{/each}
		</fieldset>
		{#if selected.length}
			<fieldset class="ordering">
				<legend>Order and width</legend>
				<p id={`${id}-width-help`} class="hint">
					Widths use pixels, from 96 to 800. Clear for auto.
				</p>
				{#each selected as col, index (col)}
					{@const property = available.get(col)!}
					<div class="column" role="group" aria-label={`${label(property)} column settings`}>
						<span class="column-name">{label(property)}</span>
						<div class="controls">
							<div class="arrows">
								<button
									type="button"
									aria-label={`Move ${label(property)} left`}
									disabled={index === 0}
									onclick={(event) => move(col, -1, event.currentTarget)}
									><IconArrowLeft size={17} aria-hidden="true" /></button
								>
								<button
									type="button"
									aria-label={`Move ${label(property)} right`}
									disabled={index === selected.length - 1}
									onclick={(event) => move(col, 1, event.currentTarget)}
									><IconArrowRight size={17} aria-hidden="true" /></button
								>
							</div>
							<label class="width">
								Width
								<input
									type="number"
									aria-label={`Width ${label(property)}`}
									aria-describedby={`${id}-width-help`}
									min="96"
									max="800"
									step="1"
									placeholder="Auto"
									value={widths[col] ?? ''}
									onchange={(event) => resize(property, event.currentTarget)}
								/>
							</label>
						</div>
					</div>
				{/each}
			</fieldset>
		{:else if available.size}
			<p class="hint">Only Record is shown.</p>
		{/if}
		<p class="status" role="status">{message}</p>
	</div>
</details>

<style>
	details {
		position: relative;
		width: fit-content;
		max-width: 100%;
		font-size: 0.875rem;
	}
	summary {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		width: fit-content;
		min-height: 2.25rem;
		padding: 0.375rem 0.625rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		color: var(--color-ink);
		background: var(--color-paper);
		cursor: pointer;
		list-style: none;
	}
	summary::-webkit-details-marker {
		display: none;
	}
	.chevron {
		display: flex;
	}
	details[open] .chevron {
		transform: rotate(180deg);
	}
	.panel {
		width: 24rem;
		max-width: 100%;
		margin-top: 0.5rem;
		padding: 1rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
	}
	fieldset {
		margin: 0;
		padding: 0;
		border: 0;
		min-width: 0;
	}
	legend {
		margin-bottom: 0.5rem;
		padding: 0;
		font-weight: 600;
	}
	.hint {
		margin: 0 0 0.75rem;
		color: var(--color-muted);
		line-height: 1.5;
		font-size: 0.8125rem;
	}
	.choices {
		display: grid;
		gap: 0.25rem;
	}
	.choice {
		display: flex;
		align-items: flex-start;
		gap: 0.625rem;
		min-height: 2rem;
		padding: 0.25rem 0;
		cursor: pointer;
	}
	.choice input {
		accent-color: var(--color-accent);
		flex: none;
		margin: 0.125rem 0 0;
		width: 1rem;
		height: 1rem;
	}
	.choice span,
	.column-name {
		overflow-wrap: anywhere;
		min-width: 0;
	}
	.ordering {
		margin-top: 1rem;
	}
	.column {
		padding: 0.625rem 0;
		border-top: 1px solid var(--color-rule);
	}
	.column-name {
		display: block;
		font-weight: 500;
	}
	.controls {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		justify-content: space-between;
		gap: 0.5rem;
		margin-top: 0.375rem;
	}
	.arrows {
		display: flex;
		gap: 0.25rem;
	}
	button {
		display: grid;
		place-items: center;
		width: 2.25rem;
		height: 2.25rem;
		padding: 0;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		color: var(--color-ink);
		background: var(--color-paper);
		cursor: pointer;
	}
	button:disabled {
		opacity: 0.4;
		cursor: default;
	}
	button:not(:disabled):hover,
	summary:hover {
		background: var(--color-bone);
	}
	.width {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		color: var(--color-muted);
		font-size: 0.8125rem;
	}
	.width input {
		width: 5.5rem;
		min-height: 2.25rem;
		padding: 0.375rem 0.5rem;
		border: 1px solid var(--color-rule);
		border-radius: var(--radius-field);
		background: var(--color-paper);
		color: var(--color-ink);
	}
	.status {
		position: absolute;
		width: 1px;
		height: 1px;
		padding: 0;
		overflow: hidden;
		clip-path: inset(50%);
		white-space: nowrap;
	}
</style>
