import type { Row } from 'iris-core/client';

/** Typed fields commit after this idle pause (and on blur); choices commit on change. */
export const TYPING_DELAY = 500;
/** The Markdown body keeps the editor's own autosave pause. */
export const MARKDOWN_DELAY = 600;
const typed = new Set(['text', 'number', 'int', 'url', 'email', 'phone', 'json']);

export function commitDelay(type?: string | null): number {
	if (type === 'markdown') return MARKDOWN_DELAY;
	return typed.has(type ?? 'text') ? TYPING_DELAY : 0;
}

export type Blocked = Record<string, { value: string; message: string }>;
type Violation = { col?: string | null; message?: string };

/** Columns a rejected patch can drop so the rest of the record still saves, or
 * null when a violation names no patched column (the write then stays failed). */
export function blockedBy(
	violations: readonly Violation[] | undefined,
	patch: Row,
	draft: Readonly<Record<string, string>>
): Blocked | null {
	if (!violations?.length) return null;
	const blocked: Blocked = {};
	for (const { col, message } of violations) {
		if (!col || col === 'id' || !Object.hasOwn(patch, col)) return null;
		blocked[col] = { value: draft[col] ?? '', message: message || 'This value cannot be saved.' };
	}
	return blocked;
}

/** The patch without columns still holding the exact value a validation refused. */
export function withoutBlocked(
	patch: Row,
	blocked: Blocked,
	draft: Readonly<Record<string, string>>
): Row | null {
	const kept: Row = {};
	for (const [col, value] of Object.entries(patch))
		if (col === 'id' || blocked[col]?.value !== (draft[col] ?? '')) kept[col] = value;
	return Object.keys(kept).some((col) => col !== 'id') ? kept : null;
}

/** Stored values from another writer replace untouched fields; local edits and the
 * focused field keep the draft. The remote row becomes the acknowledged baseline. */
export function mergeRemote(
	values: Readonly<Record<string, string>>,
	before: Readonly<Record<string, string>>,
	after: Readonly<Record<string, string>>,
	keep: ReadonlySet<string>
) {
	const columns = Object.keys(values);
	const baseline = Object.fromEntries(columns.map((column) => [column, after[column] ?? '']));
	return {
		values: Object.fromEntries(
			columns.map((column) => [
				column,
				keep.has(column) || values[column] !== (before[column] ?? '')
					? values[column]
					: baseline[column]
			])
		),
		baseline: JSON.stringify(baseline)
	};
}
