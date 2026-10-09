import type { Property, Row } from 'iris-core/client';

/** Existing rows can save page bodies without committing unrelated property drafts. */
export function markdownPatch(
	properties: Property[],
	draft: Record<string, string>,
	row: Row | null
): Row | null {
	if (!row) return null;
	const patch: Row = { id: row.id };
	for (const property of properties) {
		if (
			!Object.hasOwn(draft, property.col) ||
			property.type !== 'markdown' ||
			property.derived_by ||
			property.deprecated ||
			property.immutable
		)
			continue;
		const value = draft[property.col] ?? '';
		if (value !== String(row[property.col] ?? ''))
			patch[property.col] = value === '' ? null : value;
	}
	return Object.keys(patch).length > 1 ? patch : null;
}
