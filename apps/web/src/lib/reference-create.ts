import { isReadOnlyTable, type Property, type Row } from 'life-ui-core/client';
import { recordPatch } from './record-grid';

export type CreationTarget = { table: string; display: string; properties: Property[] };
export type CreationPlan = {
	table: string;
	/** Editable target properties, as the record editor shows them. */
	properties: Property[];
	values: Record<string, string>;
	explicit: Set<string>;
	/** Required fields, besides the name, without a catalog default. */
	missing: Property[];
};
type Source = { type?: string | null; raw: string };
type Write = (table: string, patch: Row) => Promise<Row>;

const managed = new Set(['id', 'created_at', 'updated_at', 'deleted_at', 'hub_at']);

/** The trimmed search text to offer as a new record, unless a loaded choice has that exact name. */
export function creationOffer(query: string, choices: { label: string }[]): string | null {
	const text = query.trim();
	return text && !choices.some((choice) => choice.label.trim() === text) ? text : null;
}

/** A writable target table whose display property the typed text can fill. */
export function creationTarget(
	catalog: { tables: Row[]; properties: Property[] },
	source: Property
): CreationTarget | null {
	const table = catalog.tables.find((t) => t.id === source.ref_table);
	if (!table || table.readOnly || isReadOnlyTable(String(table.id), table)) return null;
	const display = typeof table.display === 'string' ? table.display : '';
	const properties = catalog.properties
		.filter((p) => p.tbl === table.id)
		.sort((a, b) => (a.sort ?? 0) - (b.sort ?? 0) || a.col.localeCompare(b.col));
	const title = properties.find((p) => p.col === display);
	if (!title || managed.has(display) || title.derived_by || title.deprecated) return null;
	return { table: String(table.id), display, properties };
}

/** A new-record draft named by the typed text. Untouched defaults stay omitted so core applies them. */
export function creationPlan(target: CreationTarget, text: string): CreationPlan {
	const properties = target.properties.filter(
		(p) => !managed.has(p.col) && !p.derived_by && !p.deprecated
	);
	const values: Record<string, string> = {};
	for (const p of properties)
		values[p.col] = p.default_value && !p.default_value.startsWith('sql:') ? p.default_value : '';
	values[target.display] = text;
	return {
		table: target.table,
		properties,
		values,
		explicit: new Set([target.display]),
		missing: properties.filter(
			(p) => p.required && p.col !== target.display && p.default_value == null
		)
	};
}

/** The source value with the new id: a ref takes it, a multi_ref appends it once. */
export function withReference(type: string | null | undefined, raw: string, id: string) {
	if (type !== 'multi_ref') return id;
	if (!raw) return JSON.stringify([id]);
	try {
		const ids = JSON.parse(raw);
		if (!Array.isArray(ids)) return null;
		return JSON.stringify(ids.includes(id) ? ids : [...ids, id]);
	} catch {
		return null;
	}
}

/** Write the new record, then return it with the updated source value. */
export async function commitCreation(plan: CreationPlan, source: Source, write: Write) {
	if (withReference(source.type, source.raw, '') === null)
		throw Error('This reference value cannot be read. Repair it before adding a record.');
	const row = await write(plan.table, recordPatch(plan.properties, plan.values, null, plan.explicit));
	return { row, value: withReference(source.type, source.raw, String(row.id))! };
}

/** Create directly when only the name is needed; otherwise return the plan for the editor. */
export async function startCreation(
	target: CreationTarget,
	text: string,
	source: Source,
	write: Write
): Promise<CreationPlan | { row: Row; value: string }> {
	const plan = creationPlan(target, text);
	return plan.missing.length ? plan : commitCreation(plan, source, write);
}
