/** Place an open top-layer popover under its anchor: flip above when there is no
 * room below, and keep an 8px gutter inside the viewport on narrow screens. */
export function placePopover(popover: HTMLElement, anchor: Element) {
	const gutter = 8,
		gap = 4;
	const a = anchor.getBoundingClientRect();
	popover.style.maxHeight = '';
	const { width, height } = popover.getBoundingClientRect();
	const room = innerHeight - a.bottom - gap - gutter;
	const below = height <= room || a.top - gap - gutter < room;
	popover.style.left = `${Math.max(gutter, Math.min(a.left, innerWidth - width - gutter))}px`;
	popover.style.top = below ? `${a.bottom + gap}px` : '';
	popover.style.bottom = below ? '' : `${innerHeight - a.top + gap}px`;
	popover.style.maxHeight = `${Math.max(120, below ? room : a.top - gap - gutter)}px`;
}

/** Svelte action for a `popover` element: positions it against `anchor()` each
 * time it opens and reports open/closed. Closing with focus inside (Escape)
 * returns focus to the anchor. */
export function anchored(
	popover: HTMLElement,
	options: { anchor: () => Element | null | undefined; ontoggle?: (open: boolean) => void }
) {
	let current = options,
		restore = false;
	const place = () => {
		const anchor = current.anchor();
		if (anchor && popover.matches(':popover-open')) placePopover(popover, anchor);
	};
	const before = (event: Event) => {
		const anchor = current.anchor();
		if ((event as ToggleEvent).newState === 'open') {
			if (!anchor) return;
			// Start at the anchor before the first paint; `toggle` refines it.
			const a = anchor.getBoundingClientRect();
			popover.style.left = `${Math.max(8, a.left)}px`;
			popover.style.top = `${a.bottom + 4}px`;
			popover.style.bottom = '';
		} else restore = popover.contains(document.activeElement);
	};
	const toggle = (event: Event) => {
		const open = (event as ToggleEvent).newState === 'open';
		if (open) place();
		else if (restore) {
			restore = false;
			const anchor = current.anchor();
			if (anchor instanceof HTMLElement && anchor.isConnected) anchor.focus();
		}
		current.ontoggle?.(open);
	};
	popover.addEventListener('beforetoggle', before);
	popover.addEventListener('toggle', toggle);
	window.addEventListener('resize', place);
	return {
		update(next: typeof options) {
			current = next;
		},
		destroy() {
			popover.removeEventListener('beforetoggle', before);
			popover.removeEventListener('toggle', toggle);
			window.removeEventListener('resize', place);
		}
	};
}
