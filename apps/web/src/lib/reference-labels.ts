import type { WorkspaceDatabase } from './database';
import type { Property, Row } from 'iris-core/client';

const ids = (property: Property, value: unknown): unknown[] => {
	if (property.type !== 'multi_ref') return [value];
	try {
		const parsed = JSON.parse(String(value ?? '[]'));
		return Array.isArray(parsed) ? parsed : [];
	} catch {
		return [];
	}
};

/** Display labels for a page's reference cells, keyed by JSON [table, id]: one core
 * read per 200 targets. Missing and trashed targets, and tables outside
 * `tables`, are left out so cells show the stored id. */
export async function referenceLabels(
	workspace: Pick<WorkspaceDatabase, 'request'>,
	properties: Property[],
	rows: Row[],
	tables: ReadonlySet<string>
): Promise<Record<string, string>> {
	const targets = new Map<string, { table: string; id: string }>();
	for (const p of properties)
		if ((p.type === 'ref' || p.type === 'multi_ref') && p.ref_table && tables.has(p.ref_table))
			for (const row of rows)
				for (const id of ids(p, row[p.col]))
					if (typeof id === 'string' && id)
						targets.set(JSON.stringify([p.ref_table, id]), { table: p.ref_table, id });
	const all = [...targets.values()],
		labels: Record<string, string> = {};
	for (let start = 0; start < all.length; start += 200)
		for (const found of await workspace.request('mentionLabels', {
			targets: all.slice(start, start + 200)
		}))
			if (found.label !== null && !found.trashed)
				labels[JSON.stringify([found.table, found.id])] = found.label;
	return labels;
}
