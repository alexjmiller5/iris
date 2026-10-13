import { describe, expect, it } from 'vitest';
import { render } from 'svelte/server';
import { Window } from 'happy-dom';
import DownloadPrompt from './DownloadPrompt.svelte';
import type { SkippedTableDetail } from 'iris-core/client';
import {
	applyDownload,
	downloadChoices,
	hiddenPrompts,
	skippedSize,
	waitingFor,
	willDownload
} from './skipped-tables';

const detail = (extra: Partial<SkippedTableDetail> = {}): SkippedTableDetail => ({
	table: 'notes',
	rows: 62_000,
	estimatedBytes: 4_200_000,
	waitingEdits: 0,
	...extra
});
const prefs = { maxRows: 50_000, tables: { tasks: false } as Record<string, boolean> };

describe('skipped table download suggestion', () => {
	it('suggests including the table, and raising the row limit when only the limit holds it back', () => {
		expect(downloadChoices(detail(), prefs)).toEqual([
			{ kind: 'include' },
			{ kind: 'limit', maxRows: 62_000 }
		]);
		// Explicitly skipped or of unknown size: only including it downloads it.
		expect(downloadChoices(detail(), { ...prefs, tables: { notes: false } })).toEqual([
			{ kind: 'include' }
		]);
		expect(downloadChoices(detail({ rows: null }), prefs)).toEqual([{ kind: 'include' }]);
	});

	it('applies a choice without touching other tables', () => {
		expect(applyDownload({ kind: 'include' }, 'notes', prefs)).toEqual({
			maxRows: 50_000,
			tables: { tasks: false, notes: true }
		});
		expect(applyDownload({ kind: 'limit', maxRows: 62_000 }, 'notes', prefs)).toEqual({
			maxRows: 62_000,
			tables: { tasks: false }
		});
		// A raised limit clears an explicit skip so the limit decides.
		expect(
			applyDownload({ kind: 'limit', maxRows: 62_000 }, 'notes', {
				maxRows: 1,
				tables: { notes: false }
			})
		).toEqual({ maxRows: 62_000, tables: {} });
	});

	it('knows when the current settings already download it on the next round', () => {
		expect(willDownload(detail(), prefs)).toBe(false);
		expect(willDownload(detail(), { ...prefs, tables: { notes: true } })).toBe(true);
		expect(willDownload(detail(), { ...prefs, maxRows: 62_000 })).toBe(true);
		expect(willDownload(detail({ rows: null }), { ...prefs, maxRows: 1e9 })).toBe(false);
	});

	it('describes its size', () => {
		expect(skippedSize(detail())).toBe('62,000 rows · about 4.2 MB');
		expect(skippedSize(detail({ rows: 1, estimatedBytes: null }))).toBe('1 row');
		expect(skippedSize(detail({ rows: null, estimatedBytes: null }))).toBe(
			'Row count unknown until the next sync'
		);
	});

	it('sums edits waiting for skipped tables', () => {
		expect(waitingFor([detail({ waitingEdits: 2 }), detail({ table: 'tasks' })])).toEqual({
			count: 2,
			tables: ['notes']
		});
		expect(waitingFor(undefined)).toEqual({ count: 0, tables: [] });
	});
});

describe('hidden download prompts', () => {
	const memory = () => {
		const store = new Map<string, string>();
		return {
			getItem: (key: string) => store.get(key) ?? null,
			setItem: (key: string, value: string) => void store.set(key, value),
			store
		};
	};
	it('stores table names per device and reads malformed storage as none', () => {
		const storage = memory();
		const prompts = hiddenPrompts(storage);
		expect(prompts.read()).toEqual([]);
		expect(prompts.hide('notes')).toEqual(['notes']);
		expect(prompts.hide('notes')).toEqual(['notes']);
		expect(prompts.hide('tasks')).toEqual(['notes', 'tasks']);
		expect(hiddenPrompts(storage).read()).toEqual(['notes', 'tasks']);
		expect(prompts.show('notes')).toEqual(['tasks']);
		expect(storage.store.get('iris:download-prompts')).toBe('["tasks"]');
		storage.setItem('iris:download-prompts', '{bad');
		expect(prompts.read()).toEqual([]);
		storage.setItem('iris:download-prompts', '[1,"ok"]');
		expect(prompts.read()).toEqual(['ok']);
	});
	it('keeps working when storage throws', () => {
		const prompts = hiddenPrompts({
			getItem() {
				throw new Error('blocked');
			},
			setItem() {
				throw new Error('blocked');
			}
		});
		expect(prompts.read()).toEqual([]);
		expect(prompts.hide('notes')).toEqual(['notes']);
	});
});

describe('download prompt', () => {
	const html = (d: SkippedTableDetail, p = prefs) => {
		const win = new Window();
		win.document.body.innerHTML = render(DownloadPrompt, {
			props: { detail: d, prefs: p, onapprove() {}, ondismiss() {} }
		}).body;
		return win;
	};
	it('explains the table is read-only, shows its size and the suggested settings', () => {
		const win = html(detail({ waitingEdits: 2 }));
		const doc = win.document;
		expect(doc.querySelector('dialog')?.getAttribute('aria-labelledby')).toBe(
			'download-prompt-title'
		);
		expect(doc.getElementById('download-prompt-title')?.textContent).toBe(
			'Not synced on this device'
		);
		expect(
			doc.getElementById('download-prompt-description')?.textContent?.replace(/\s+/g, ' ').trim()
		).toBe(
			'Its records here are read-only and may be incomplete. Download it to edit them. 2 earlier edits upload once it syncs.'
		);
		expect(doc.querySelector('.size')?.textContent).toBe('62,000 rows · about 4.2 MB');
		const radios = [...doc.querySelectorAll('input[type=radio]')];
		expect(radios.map((r) => [r.getAttribute('value'), r.hasAttribute('checked')])).toEqual([
			['include', true],
			['limit', false]
		]);
		expect(doc.querySelector('label.hide')?.textContent?.trim()).toBe(
			"Don't show this again for this table"
		);
		expect([...doc.querySelectorAll('footer button')].map((b) => b.textContent)).toEqual([
			'Not now',
			'Download'
		]);
		win.close();
	});
	it('offers only including a table the settings skip explicitly', () => {
		const win = html(detail(), { ...prefs, tables: { notes: false } });
		expect(win.document.querySelectorAll('input[type=radio]').length).toBe(1);
		win.close();
	});
});
