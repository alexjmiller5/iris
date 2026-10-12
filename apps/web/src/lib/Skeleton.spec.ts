import { readFileSync } from 'node:fs';
import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import { Window } from 'happy-dom';
import Skeleton from './Skeleton.svelte';
import { skeletonElement } from './skeleton';

function mount(props: Record<string, unknown>) {
	const window = new Window();
	window.document.body.innerHTML = render(Skeleton, { props: props as never }).body;
	return window;
}

test('a placeholder is busy, announced as loading, and hides its bars', () => {
	const window = mount({ shape: 'list', rows: 4, label: 'Loading tables' });
	const box = window.document.querySelector('[aria-busy="true"]');
	expect(box?.getAttribute('role')).toBe('status');
	expect(box?.querySelector('.skeleton-label')?.textContent).toBe('Loading tables');
	const rows = box?.querySelectorAll('.row') ?? [];
	expect(rows.length).toBe(4);
	for (const row of rows) expect(row.getAttribute('aria-hidden')).toBe('true');
	expect(box?.textContent?.trim()).toBe('Loading tables');
	window.close();
});

test('a placeholder beside its own status line stays quiet', () => {
	const window = mount({ shape: 'list', announce: false });
	const box = window.document.querySelector('[aria-busy="true"]');
	expect(box?.hasAttribute('role')).toBe(false);
	window.close();
});

test('grid rows take the grid column widths', () => {
	const window = mount({ shape: 'grid', rows: 2, columns: [280, 180, 96] });
	const rows = window.document.querySelectorAll('.row');
	expect(rows.length).toBe(2);
	expect((rows[0] as unknown as HTMLElement).style.gridTemplateColumns).toBe('280px 180px 96px');
	expect(rows[0].querySelectorAll('.skeleton-bar').length).toBe(3);
	window.close();
});

test('a reference label placeholder is one inline pill', () => {
	const window = mount({ shape: 'pill' });
	const box = window.document.querySelector('[aria-busy="true"]');
	expect(box?.tagName).toBe('SPAN');
	expect(box?.querySelectorAll('.skeleton-bar.pill').length).toBe(1);
	expect(box?.textContent).toBe('Loading');
	window.close();
});

test('node views outside Svelte build the same placeholder', () => {
	const window = new Window();
	const box = skeletonElement(window.document as unknown as Document, { lines: 3 });
	expect(box.getAttribute('aria-busy')).toBe('true');
	expect(box.querySelectorAll('.skeleton-bar').length).toBe(3);
	expect(box.querySelector('.skeleton-label')?.textContent).toBe('Loading');
	window.close();
});

test('placeholder tokens exist in both themes and the highlight stops under reduced motion', () => {
	const css = readFileSync(new URL('../theme.css', import.meta.url), 'utf8');
	const [light, dark] = css.split('@media (prefers-color-scheme: dark)');
	for (const block of [light, dark.slice(0, dark.indexOf('\n}\n'))]) {
		expect(block).toMatch(/--color-skeleton:\s*#[0-9a-f]{6}/);
		expect(block).toMatch(/--color-skeleton-shine:/);
	}
	expect(css).toMatch(
		/@media \(prefers-reduced-motion: reduce\)\s*\{\s*\.skeleton-bar,\s*\.skeleton-field\s*\{\s*animation: none;/
	);
});
