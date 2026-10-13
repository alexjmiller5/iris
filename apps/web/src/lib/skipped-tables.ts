import type { SkippedTableDetail } from 'iris-core/client';
import { formatBytes } from './backup';

/** This device's download settings, as sync receives them. */
export type DownloadPrefs = { maxRows: number; tables: Record<string, boolean> };
/** A setting that makes a skipped table download: include it, or raise the row limit to its size. */
export type DownloadChoice = { kind: 'include' } | { kind: 'limit'; maxRows: number };

/** Including the table always works; a higher limit works only when the limit alone left it out. */
export function downloadChoices(
	detail: SkippedTableDetail,
	prefs: DownloadPrefs
): DownloadChoice[] {
	const limited =
		prefs.tables[detail.table] === undefined && detail.rows !== null && detail.rows > prefs.maxRows;
	return limited
		? [{ kind: 'include' }, { kind: 'limit', maxRows: detail.rows! }]
		: [{ kind: 'include' }];
}

export function applyDownload(
	choice: DownloadChoice,
	table: string,
	prefs: DownloadPrefs
): DownloadPrefs {
	if (choice.kind === 'include') return { ...prefs, tables: { ...prefs.tables, [table]: true } };
	const tables = { ...prefs.tables };
	delete tables[table];
	return { maxRows: choice.maxRows, tables };
}

/** The next round downloads it with these settings (it stays skipped until that round completes). */
export function willDownload(detail: SkippedTableDetail, prefs: DownloadPrefs): boolean {
	const choice = prefs.tables[detail.table];
	return choice ?? (detail.rows !== null && detail.rows <= prefs.maxRows);
}

export function skippedSize(detail: SkippedTableDetail): string {
	if (detail.rows === null) return 'Row count unknown until the next sync';
	const rows = `${detail.rows.toLocaleString('en-US')} ${detail.rows === 1 ? 'row' : 'rows'}`;
	return detail.estimatedBytes ? `${rows} · about ${formatBytes(detail.estimatedBytes)}` : rows;
}

/** Pending edits in tables this device skips: they upload once the table syncs again. */
export function waitingFor(details: readonly SkippedTableDetail[] | undefined) {
	const waiting = (details ?? []).filter((d) => d.waitingEdits > 0);
	return {
		count: waiting.reduce((n, d) => n + d.waitingEdits, 0),
		tables: waiting.map((d) => d.table)
	};
}

type PromptStorage = Pick<Storage, 'getItem' | 'setItem'>;
const KEY = 'iris:download-prompts';

/** Tables whose download prompt this device no longer shows. A per-device convenience: never
 * synced and never consulted for writes, which core refuses on its own. */
export function hiddenPrompts(storage: PromptStorage) {
	const read = (): string[] => {
		try {
			const value = JSON.parse(storage.getItem(KEY) ?? '[]');
			return Array.isArray(value) ? value.filter((t) => typeof t === 'string') : [];
		} catch {
			return [];
		}
	};
	const write = (tables: string[]) => {
		try {
			storage.setItem(KEY, JSON.stringify(tables));
		} catch {
			/* The prompt simply shows again next time. */
		}
		return tables;
	};
	return {
		read,
		hide: (table: string) => write([...new Set([...read(), table])]),
		show: (table: string) => write(read().filter((t) => t !== table))
	};
}
