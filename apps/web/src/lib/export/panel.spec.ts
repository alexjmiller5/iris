import { expect, test } from 'vitest';
import { render } from 'svelte/server';
import { Window } from 'happy-dom';
import ExportPanel from './ExportPanel.svelte';

test('initial export controls and explanatory text are inside a collapsed native disclosure', () => {
	const window = new Window();
	window.document.body.innerHTML = render(ExportPanel, { props: { snapshot: null } }).body;
	const details = window.document.querySelector('details');
	expect(details).not.toBeNull();
	expect(details?.hasAttribute('open')).toBe(false);
	expect(details?.querySelector('summary')?.textContent?.trim()).toBe('Export');
	expect(details?.querySelector('select[aria-label="Export format"]')).not.toBeNull();
	expect(details?.querySelector('button')?.textContent?.trim()).toBe('Export loaded rows');
	expect(details?.textContent).toContain('Stored values only.');
	window.happyDOM.abort();
});
