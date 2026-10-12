/** Varied bar widths (percent) so placeholder rows read as text rather than a ruled grid. */
const WIDTHS = [72, 54, 86, 63, 45, 78, 58, 91];
export const barWidth = (index: number) => WIDTHS[index % WIDTHS.length];

/** Skeleton.svelte for DOM node views outside Svelte (editor embeds, images): `lines` bars
 *  in an aria-busy box with a visually hidden label. */
export function skeletonElement(
	document: Document,
	{
		lines = 2,
		block = false,
		label = 'Loading'
	}: { lines?: number; block?: boolean; label?: string } = {}
): HTMLElement {
	const box = document.createElement('span');
	box.className = 'skeleton';
	box.setAttribute('role', 'status');
	box.setAttribute('aria-busy', 'true');
	const text = document.createElement('span');
	text.className = 'skeleton-label';
	text.textContent = label;
	box.appendChild(text);
	for (let i = 0; i < (block ? 1 : lines); i++) {
		const bar = document.createElement('span');
		bar.className = 'skeleton-bar';
		bar.setAttribute('aria-hidden', 'true');
		// An image placeholder is a preview-sized block; text placeholders are line bars.
		bar.style.width = block ? '12rem' : `${barWidth(i)}%`;
		if (block) bar.style.height = '8rem';
		box.appendChild(bar);
	}
	return box;
}
