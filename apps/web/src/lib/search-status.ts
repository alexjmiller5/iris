import type { Property, SearchHit } from 'life-ui-core/client';

export type StatusHit = SearchHit & { status?: { v: string; d?: string } };

/** Labels hits with their lifecycle status: the select column named `status`, the
 * one lifecycle column of life-data's estate status dictionary. The label and its
 * help come from the stored value and its catalog option description. */
export async function labelStatus(
	hits: SearchHit[],
	properties: Property[],
	read: (table: string, id: string) => Promise<unknown>
): Promise<StatusHit[]> {
	return Promise.all(
		hits.map(async (hit) => {
			const p = properties.find(
				(p) => p.tbl === hit.table && p.col === 'status' && p.type === 'select'
			);
			if (!p) return hit;
			const v = await read(hit.table, hit.id).catch(() => null);
			if (typeof v !== 'string' || !v) return hit;
			return { ...hit, status: { v, d: p.options?.find((o) => o.v === v)?.d } };
		})
	);
}
