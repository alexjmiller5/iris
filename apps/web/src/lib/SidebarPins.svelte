<script lang="ts">
	import BreakName from './BreakName.svelte';
	import { IconMenu2, IconPin, IconTrash } from '@tabler/icons-svelte';
	import type { SidebarPin } from 'iris-core/client';
	import { tick } from 'svelte';
	import { anchored, placePopover } from './popover';
	import { dropIndex } from './sidebar-pins';
	let {
		pins,
		current,
		disabled,
		mutationDisabled,
		error,
		onchoose,
		onunpin,
		onreorder,
		onretry
	}: {
		pins: SidebarPin[];
		current: string;
		disabled: boolean;
		mutationDisabled: boolean;
		error: string | null;
		onchoose: (table: string) => unknown;
		onunpin: (id: string) => unknown;
		/** Moves a pin to an index of `pins`; resolves true once acknowledged. */
		onreorder: (id: string, to: number) => Promise<boolean>;
		onretry: () => unknown;
	} = $props();
	const uid = $props.id();
	const locked = $derived(disabled || mutationDisabled);
	let list = $state<HTMLElement>(),
		menu = $state<HTMLElement>(),
		menuAnchor = $state<HTMLElement>(),
		menuPin = $state<SidebarPin | null>(null),
		announcement = $state('');
	/** A drag in progress, or settling until the reordered list arrives. */
	let drag = $state<{
		id: string;
		order: string;
		from: number;
		to: number;
		startY: number;
		dy: number;
		centres: number[];
		height: number;
		settling: boolean;
	} | null>(null);
	const order = $derived(pins.map((pin) => pin.id).join('\n'));
	function offset(index: number) {
		// Once the acknowledged order arrives the rows sit in place on their own.
		if (!drag || drag.order !== order) return undefined;
		const { from, to, dy, height } = drag;
		if (index === from) return `translateY(${dy}px)`;
		if (from < to && index > from && index <= to) return `translateY(${-height}px)`;
		if (to < from && index >= to && index < from) return `translateY(${height}px)`;
	}
	async function reorder(pin: SidebarPin, to: number, refocus: boolean) {
		const moved = await onreorder(pin.id, to);
		if (moved) announcement = `${pin.tbl} moved to position ${to + 1} of ${pins.length}.`;
		if (!refocus) return;
		await tick();
		list?.querySelector<HTMLElement>(`[data-pin-table="${CSS.escape(pin.tbl)}"] .handle`)?.focus();
	}
	function startDrag(event: PointerEvent, index: number, pin: SidebarPin) {
		if (locked || drag || event.button !== 0 || !list) return;
		event.preventDefault();
		(event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
		const rows = [...list.querySelectorAll('.pin')].map((row) => row.getBoundingClientRect());
		const gap = rows.length > 1 ? rows[1].top - rows[0].bottom : 0;
		drag = {
			id: pin.id,
			order,
			from: index,
			to: index,
			startY: event.clientY,
			dy: 0,
			centres: rows.map((row) => row.top + row.height / 2),
			height: rows[index].height + gap,
			settling: false
		};
	}
	function moveDrag(event: PointerEvent) {
		if (!drag || drag.settling) return;
		drag.dy = event.clientY - drag.startY;
		drag.to = dropIndex(drag.centres, drag.from, drag.centres[drag.from] + drag.dy);
	}
	async function endDrag(pin: SidebarPin, cancelled: boolean) {
		if (!drag || drag.settling) return;
		if (cancelled || drag.to === drag.from) {
			drag = null;
			return;
		}
		drag.settling = true;
		try {
			await reorder(pin, drag.to, false);
		} finally {
			drag = null;
		}
	}
	function keyMove(event: KeyboardEvent, index: number, pin: SidebarPin) {
		if (event.key === 'Escape' && drag) return endDrag(pin, true);
		if (!event.altKey || (event.key !== 'ArrowUp' && event.key !== 'ArrowDown')) return;
		event.preventDefault();
		const to = index + (event.key === 'ArrowUp' ? -1 : 1);
		if (!locked && to >= 0 && to < pins.length) void reorder(pin, to, true);
	}
	function openMenu(pin: SidebarPin, anchor: HTMLElement) {
		if (!menu) return;
		menuPin = pin;
		menuAnchor = anchor;
		// Another pin's menu moves to this row.
		if (menu.matches(':popover-open')) placePopover(menu, anchor);
		else menu.showPopover();
		menu.querySelector<HTMLElement>('[role="menuitem"]')?.focus();
	}
	function closeMenu() {
		if (menu?.matches(':popover-open')) menu.hidePopover();
	}
	function rowControl(event: Event, row: HTMLElement) {
		return (event.target as Element).closest<HTMLElement>('button') ?? row;
	}
	// Long press opens the menu, as right-click and Shift+F10 do.
	let press: ReturnType<typeof setTimeout> | undefined,
		pressStart = { x: 0, y: 0 },
		pressed = false;
	function startPress(event: PointerEvent, pin: SidebarPin) {
		pressed = false;
		clearTimeout(press);
		if ((event.target as Element).closest('.handle') || event.button !== 0) return;
		const row = event.currentTarget as HTMLElement;
		pressStart = { x: event.clientX, y: event.clientY };
		press = setTimeout(() => {
			pressed = true;
			openMenu(pin, row);
		}, 500);
	}
	function trackPress(event: PointerEvent) {
		if (Math.hypot(event.clientX - pressStart.x, event.clientY - pressStart.y) > 8)
			clearTimeout(press);
	}
	$effect(() => {
		// The menu belongs to a pin that is still listed.
		if (menuPin && !pins.some((pin) => pin.id === menuPin?.id)) closeMenu();
	});
</script>

{#if pins.length}
	<nav aria-label="Pinned tables" class:dragging={drag && !drag.settling} bind:this={list}>
		<h2>Pinned tables</h2>
		{#each pins as pin, index (pin.id)}
			<div
				class="pin"
				class:lifted={drag?.id === pin.id}
				data-pin-table={pin.tbl}
				style:transform={offset(index)}
				role="none"
				oncontextmenu={(event) => {
					event.preventDefault();
					clearTimeout(press);
					openMenu(pin, rowControl(event, event.currentTarget));
				}}
				onkeydown={(event) => {
					if (event.key === 'ContextMenu' || (event.shiftKey && event.key === 'F10')) {
						event.preventDefault();
						openMenu(pin, rowControl(event, event.currentTarget));
					}
				}}
				onpointerdown={(event) => startPress(event, pin)}
				onpointermove={trackPress}
				onpointerup={() => clearTimeout(press)}
				onpointercancel={() => clearTimeout(press)}
				onpointerleave={() => clearTimeout(press)}
			>
				<button
					class="destination"
					class:active={current === pin.tbl}
					aria-current={current === pin.tbl ? 'page' : undefined}
					aria-label={`Open pinned ${pin.tbl}`}
					disabled={disabled || !!pin.unavailable}
					onclick={() => {
						// The click that ends a long press only closes it.
						if (!pressed) onchoose(pin.tbl);
						pressed = false;
					}}><IconPin size={16} /><span><BreakName name={pin.tbl} /></span></button
				>
				<button
					class="handle"
					type="button"
					aria-label={`Reorder ${pin.tbl}`}
					aria-keyshortcuts="Alt+ArrowUp Alt+ArrowDown"
					title="Drag to reorder (Alt+Up or Alt+Down)"
					aria-disabled={locked}
					onpointerdown={(event) => startDrag(event, index, pin)}
					onpointermove={moveDrag}
					onpointerup={() => endDrag(pin, false)}
					onpointercancel={() => endDrag(pin, true)}
					onlostpointercapture={() => endDrag(pin, true)}
					onkeydown={(event) => keyMove(event, index, pin)}><IconMenu2 size={16} /></button
				>
				{#if pin.unavailable}<small>{pin.unavailable}</small>{/if}
			</div>
		{/each}
	</nav>
{/if}
<p class="sr-only" aria-live="polite">{announcement}</p>
<div
	id={`${uid}-pin-menu`}
	popover="manual"
	role="menu"
	tabindex="-1"
	aria-label={menuPin ? `Pin actions for ${menuPin.tbl}` : 'Pin actions'}
	class="pin-menu"
	bind:this={menu}
	use:anchored={{ anchor: () => menuAnchor }}
	onkeydown={(event) => {
		if (event.key === 'Escape') {
			event.preventDefault();
			closeMenu();
		}
	}}
	onfocusout={(event) => {
		if (!menu?.contains(event.relatedTarget as Node | null)) closeMenu();
	}}
>
	<button
		type="button"
		role="menuitem"
		aria-disabled={locked}
		onclick={() => {
			const pin = menuPin;
			if (locked || !pin) return;
			closeMenu();
			onunpin(pin.id);
		}}><IconTrash size={16} aria-hidden="true" />Unpin</button
	>
</div>
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
		border-radius: var(--radius-field);
		/* Long press opens the pin menu instead of the system callout. */
		-webkit-touch-callout: none;
		-webkit-user-select: none;
		user-select: none;
	}
	.dragging .pin {
		transition: transform 150ms ease-out;
	}
	.dragging .pin.lifted {
		position: relative;
		z-index: 1;
		transition: none;
		background: var(--color-paper);
		box-shadow:
			0 8px 20px -10px rgb(21 24 28 / 0.35),
			0 1px 3px rgb(21 24 28 / 0.12);
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
	/* A missing table's row still takes right-click and long press. */
	.destination:disabled {
		pointer-events: none;
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
	.handle {
		cursor: grab;
		touch-action: none;
	}
	.dragging .handle {
		cursor: grabbing;
	}
	button:hover:not(:disabled, [aria-disabled='true']) {
		background: var(--color-accent-soft);
	}
	/* Pin controls stay focusable while pins briefly reload; they act once ready. */
	button:disabled,
	button[aria-disabled='true'] {
		opacity: 0.5;
		cursor: default;
	}
	small {
		width: 100%;
		padding: 0 8px 6px;
		color: var(--color-muted);
	}
	.pin-menu {
		position: fixed;
		inset: auto;
		margin: 0;
		min-width: 10rem;
		padding: 4px;
		border: 1px solid var(--color-rule);
		border-radius: 8px;
		background: var(--color-paper);
		color: var(--color-ink);
		box-shadow:
			0 12px 32px -12px rgb(21 24 28 / 0.28),
			0 2px 6px rgb(21 24 28 / 0.08);
	}
	.pin-menu button {
		justify-content: start;
		width: 100%;
		padding: 0 8px;
		font: inherit;
		font-size: 13px;
		color: var(--color-violation);
	}
	.pin-menu button:hover:not(:disabled, [aria-disabled='true']),
	.pin-menu button:focus-visible {
		background: var(--color-bone);
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
