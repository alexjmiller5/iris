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
	let current = options;
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
		} else if (
			popover.contains(document.activeElement) &&
			anchor instanceof HTMLElement &&
			anchor.isConnected
		)
			// Synchronously, while the popover is still open: the browser then has no
			// focus of its own to restore, and no queued handler can take focus back
			// after the user has moved on.
			anchor.focus();
	};
	const toggle = (event: Event) => {
		const open = (event as ToggleEvent).newState === 'open';
		if (open) place();
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

/** For a modal that unmounts instead of closing natively, which would otherwise
 * drop focus on the body: call while its opener still has focus (component
 * setup); the returned function, run on destroy, puts focus back there unless
 * something else has taken it. */
export function focusReturn() {
	const opener = typeof document === 'undefined' ? null : document.activeElement;
	return () => {
		if (!opener) return;
		const now = document.activeElement;
		if (opener instanceof HTMLElement && opener.isConnected && (!now || now === document.body))
			opener.focus();
	};
}
