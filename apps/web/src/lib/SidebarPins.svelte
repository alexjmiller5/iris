<script lang="ts">
	import { IconPin, IconPinnedOff, IconChevronUp, IconChevronDown } from '@tabler/icons-svelte';
	import type { SidebarPin } from 'iris-core/client';
	let {
		pins,
		current,
		disabled,
		mutationDisabled,
		error,
		onchoose,
		onunpin,
		onmove,
		onretry
	}: {
		pins: SidebarPin[];
		current: string;
		disabled: boolean;
		mutationDisabled: boolean;
		error: string | null;
		onchoose: (table: string) => unknown;
		onunpin: (id: string) => unknown;
		onmove: (id: string, direction: 'up' | 'down') => unknown;
		onretry: () => unknown;
	} = $props();
</script>

{#if pins.length}
	<nav aria-label="Pinned tables">
		<h2>Pinned tables</h2>
		{#each pins as pin, index (pin.id)}
			<div class="pin" data-pin-table={pin.tbl}>
				<button
					class="destination"
					class:active={current === pin.tbl}
					aria-current={current === pin.tbl ? 'page' : undefined}
					aria-label={`Open pinned ${pin.tbl}`}
					disabled={disabled || !!pin.unavailable}
					onclick={() => onchoose(pin.tbl)}><IconPin size={16} /><span>{pin.tbl}</span></button
				>
				<div class="actions">
					<button
						aria-label={`Move ${pin.tbl} up`}
						title="Move up"
						disabled={disabled || mutationDisabled || index === 0}
						onclick={() => onmove(pin.id, 'up')}><IconChevronUp size={16} /></button
					>
					<button
						aria-label={`Move ${pin.tbl} down`}
						title="Move down"
						disabled={disabled || mutationDisabled || index === pins.length - 1}
						onclick={() => onmove(pin.id, 'down')}><IconChevronDown size={16} /></button
					>
					<button
						aria-label={`Unpin ${pin.tbl}`}
						title="Unpin table"
						disabled={disabled || mutationDisabled}
						onclick={() => onunpin(pin.id)}><IconPinnedOff size={16} /></button
					>
				</div>
				{#if pin.unavailable}<small>{pin.unavailable}</small>{/if}
			</div>
		{/each}
	</nav>
{/if}
{#if error}<div class="pin-error" role="status">
		<p>{error}</p>
		<button {disabled} onclick={onretry}>Retry pins</button>
	</div>{/if}

<style>
	nav {
		display: grid;
		gap: 3px;
		min-width: 0;
	}
	h2 {
		font-size: 12px;
		font-weight: 600;
		color: var(--color-muted);
		margin: 0;
		padding: 6px 8px;
	}
	.pin {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		min-width: 0;
	}
	button {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		border: 0;
		border-radius: var(--radius-field);
		background: none;
		color: var(--color-muted);
		cursor: pointer;
		min-height: 36px;
		min-width: 32px;
	}
	.destination {
		flex: 1;
		min-width: 0;
		padding: 10px 8px;
		justify-content: start;
		font-size: 13px;
		font-weight: 500;
		text-align: left;
	}
	.destination span {
		overflow-wrap: anywhere;
	}
	.destination :global(svg) {
		flex: none;
	}
	.active {
		color: var(--color-accent);
		background: var(--color-accent-soft);
	}
	.actions {
		display: flex;
	}
	button:hover:not(:disabled) {
		background: var(--color-accent-soft);
	}
	button:disabled {
		opacity: 0.5;
		cursor: default;
	}
	small {
		width: 100%;
		padding: 0 8px 6px;
		color: var(--color-muted);
	}
	.pin-error {
		font-size: 12px;
		color: var(--color-muted);
		padding: 0 8px;
	}
	.pin-error p {
		margin: 4px 0;
	}
	@media (max-width: 700px) {
		button {
			min-height: 44px;
			min-width: 44px;
		}
	}
</style>
