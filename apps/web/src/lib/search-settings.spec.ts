import { describe, expect, it } from 'vitest';
import { render } from 'svelte/server';
import { Window } from 'happy-dom';
import type { SearchTable } from 'iris-core/client';
import { searchChoice, searchTableDetail } from './search-settings';
import SearchSettings from './SearchSettings.svelte';

const row = (table: string, extra: Partial<SearchTable> = {}): SearchTable => ({
	table,
	indexed: true,
	defaultExclusion: null,
	override: null,
	rows: 6105,
	textBytes: 31_200_000,
	...extra
});

describe('search table settings', () => {
	it('describes records, text to index and why a default leaves a table out', () => {
		expect(searchTableDetail(row('tasks'), 50_000)).toBe('6,105 records · about 31.2 MB of text');
		expect(searchTableDetail(row('one', { rows: 1, textBytes: 12 }), 50_000)).toBe(
			'1 record · about 12 bytes of text'
		);
		expect(
			searchTableDetail(
				row('provenance', { indexed: false, defaultExclusion: 'provenance' }),
				50_000
			)
		).toBe('6,105 records · about 31.2 MB of text · Off by default: provenance links');
		expect(
			searchTableDetail(
				row('history', { defaultExclusion: 'size', override: true, rows: 420_000 }),
				50_000
			)
		).toBe('420,000 records · about 31.2 MB of text · Off by default: over 50,000 records');
	});

	it('turning a table back to its default clears the choice instead of storing it', () => {
		expect(searchChoice(row('tasks'), false)).toBe(false);
		expect(searchChoice(row('tasks', { indexed: false, override: false }), true)).toBeNull();
		expect(searchChoice(row('big', { indexed: false, defaultExclusion: 'size' }), true)).toBe(true);
		expect(
			searchChoice(row('big', { defaultExclusion: 'size', override: true }), false)
		).toBeNull();
	});

	it('opens from a sidebar button into a labelled dialog', () => {
		const win = new Window();
		win.document.body.innerHTML = render(SearchSettings, {
			props: { database: {} as never }
		}).body;
		const doc = win.document;
		expect(doc.querySelector('button.open')?.textContent?.trim()).toBe('Search index');
		expect(doc.querySelector('dialog')?.getAttribute('aria-labelledby')).toBe(
			'search-settings-title'
		);
		expect(doc.getElementById('search-settings-title')?.textContent).toBe('Search index');
		win.close();
	});
});
