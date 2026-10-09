import type { Property, Row } from 'iris-core/client';
export type CellKey = { rowId: string; column: string };
export type CellDraft = { cell: CellKey; baseline: Row; raw: string };
export type CellState = {
	edit: CellDraft | null;
	phase: 'idle' | 'loading' | 'editing' | 'saving';
	error: string;
};
export function rawValue(value: unknown): string {
	return value == null ? '' : typeof value === 'string' ? value : JSON.stringify(value);
}
function fieldValue(property: Property, raw: string): unknown {
	const number = Number(raw);
	const numeric = ['number', 'int', 'bool'].includes(property.type ?? '');
	const value =
		raw === '' || (numeric && raw.trim() === '')
			? null
			: numeric && Number.isFinite(number)
				? number
				: raw;
	return value;
}
export function cellPatch(property: Property, edit: CellDraft): Row {
	return { id: edit.cell.rowId, [edit.cell.column]: fieldValue(property, edit.raw) };
}
const managed = new Set(['id', 'created_at', 'updated_at', 'deleted_at', 'hub_at']);
export function duplicateValues(properties: Property[], row: Row): Record<string, string> {
	return Object.fromEntries(
		properties
			.filter(
				(p) => !managed.has(p.col) && !p.derived_by && !p.deprecated && Object.hasOwn(row, p.col)
			)
			.map((p) => [p.col, rawValue(row[p.col])])
	);
}
export function moveCell(
	rows: readonly Row[],
	columns: readonly string[],
	cell: CellKey,
	dx: number,
	dy: number,
	wrap = false
): CellKey | null {
	let r = rows.findIndex((row) => String(row.id) === cell.rowId),
		c = columns.indexOf(cell.column);
	if (r < 0 || c < 0)
		return rows[0] && columns[0] ? { rowId: String(rows[0].id), column: columns[0] } : null;
	r += dy;
	c += dx;
	if (wrap && c >= columns.length) {
		c = 0;
		r++;
	}
	if (wrap && c < 0) {
		c = columns.length - 1;
		r--;
	}
	if (r < 0 || r >= rows.length || c < 0 || c >= columns.length) return null;
	return { rowId: String(rows[r].id), column: columns[c] };
}
export function createCellEditor(publish: (state: CellState) => void) {
	let state: CellState = { edit: null, phase: 'idle', error: '' },
		generation = 0;
	function set(next: CellState) {
		state = next;
		publish(state);
	}
	function discard() {
		if (state.phase === 'saving') return false;
		generation++;
		set({ edit: null, phase: 'idle', error: '' });
		return true;
	}
	return {
		get state() {
			return state;
		},
		discard,
		async begin(cell: CellKey, load: () => Promise<Row | false>) {
			if (state.phase === 'saving') return;
			const request = ++generation;
			set({ edit: null, phase: 'loading', error: '' });
			try {
				const row = await load();
				if (request !== generation) return;
				set(
					row
						? {
								edit: { cell: { ...cell }, baseline: { ...row }, raw: rawValue(row[cell.column]) },
								phase: 'editing',
								error: ''
							}
						: { edit: null, phase: 'idle', error: '' }
				);
			} catch (error) {
				if (request === generation)
					set({
						edit: null,
						phase: 'idle',
						error: error instanceof Error ? error.message : 'Record could not be opened.'
					});
			}
		},
		change(raw: string) {
			if (state.phase === 'editing' && state.edit)
				set({ ...state, edit: { ...state.edit, raw }, error: '' });
		},
		// Keep the complete accepted row for an action that follows this save.
		// true means no write was needed; false means the caller must stay put.
		async commit(save: (edit: CellDraft) => Promise<Row>): Promise<Row | boolean> {
			if (state.phase === 'saving' || state.phase === 'loading') return false;
			const edit = state.edit;
			if (!edit) return true;
			if (edit.raw === rawValue(edit.baseline[edit.cell.column])) {
				discard();
				return true;
			}
			const request = generation;
			set({ ...state, phase: 'saving', error: '' });
			try {
				const stored = await save(edit);
				if (request !== generation) return false;
				set({ edit: null, phase: 'idle', error: '' });
				return stored;
			} catch (error) {
				if (request === generation)
					set({
						edit,
						phase: 'editing',
						error:
							error instanceof Error
								? error.message
								: 'Cell could not be saved. Your draft is kept.'
					});
				return false;
			}
		}
	};
}

/** Input serialization only; the shared writer owns catalog and value validation. */
export function recordPatch(
	properties: Property[],
	draft: Record<string, string>,
	row: Row | null,
	explicit: ReadonlySet<string>,
	copied: Row = {}
): Row {
	const patch: Row = row ? { id: row.id } : {};
	for (const property of properties) {
		if (
			managed.has(property.col) ||
			property.derived_by ||
			property.deprecated ||
			(row && property.immutable)
		)
			continue;
		if (!Object.hasOwn(draft, property.col)) continue;
		const raw = draft[property.col];
		if (
			row
				? raw === rawValue(row[property.col])
				: !explicit.has(property.col) && !Object.hasOwn(copied, property.col)
		)
			continue;
		// An untouched copy retains SQLite scalars, including empty text versus NULL.
		patch[property.col] =
			!row && !explicit.has(property.col) && Object.hasOwn(copied, property.col)
				? copied[property.col]
				: fieldValue(property, raw);
	}
	return patch;
}
