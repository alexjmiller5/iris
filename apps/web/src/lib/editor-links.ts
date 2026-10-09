import type { CoreHandlers, MentionLabel, ViewEmbed } from 'iris-core/client';
import { calendarContext } from './calendar-context';

/** The read-only core operations the editor may ask its host for. */
export type LinkOp = 'catalog' | 'search' | 'listViews' | 'mentionLabels' | 'viewEmbed';
export type LinkRequest = <K extends LinkOp>(
	op: K,
	args: Parameters<CoreHandlers[K]>[0]
) => Promise<Awaited<ReturnType<CoreHandlers[K]>>>;
export interface MentionTable {
	id: string;
	command: string;
}
export interface LinkTarget {
	table: string;
	id: string;
	label: string;
}
export interface EditorLinks {
	tables(): Promise<MentionTable[]>;
	search(table: string | undefined, text: string): Promise<LinkTarget[]>;
	views(): Promise<{ table: string; id: string; name: string }[]>;
	label(table: string, id: string): Promise<MentionLabel>;
	embed(table: string, viewId: string): Promise<ViewEmbed>;
}

const IRREGULAR: Record<string, string> = { people: 'person', children: 'child', men: 'man', women: 'woman' };
/** Generic English, so `/person` finds a `people` table without naming any user table. */
export function singular(id: string): string {
	const [head, last] = [id.slice(0, id.lastIndexOf('_') + 1), id.slice(id.lastIndexOf('_') + 1)];
	const word =
		IRREGULAR[last] ??
		(/ies$/.test(last)
			? last.slice(0, -3) + 'y'
			: /(s|x|z|ch|sh)es$/.test(last)
				? last.slice(0, -2)
				: /(ss|us|is)$/.test(last) || !last.endsWith('s')
					? last
					: last.slice(0, -1));
	return head + word;
}

export type SlashMatch = { kind: 'mention' } | { kind: 'view' } | { kind: 'table'; table: MentionTable };
export function slashMatches(query: string, tables: MentionTable[]): SlashMatch[] {
	const q = query.trim().toLowerCase();
	const hit = (...words: string[]) => words.some((word) => word.toLowerCase().startsWith(q));
	return [
		...(hit('mention') ? [{ kind: 'mention' } as const] : []),
		...(hit('view', 'embed') ? [{ kind: 'view' } as const] : []),
		...(q ? tables.filter((t) => hit(t.command, t.id)).map((table) => ({ kind: 'table', table }) as const) : [])
	];
}

export function cellText(value: unknown, type: string): string {
	if (value === null || value === undefined) return '';
	if (type === 'bool') return value ? 'Yes' : 'No';
	if (type === 'multi_select' && typeof value === 'string') {
		try {
			const list = JSON.parse(value);
			if (Array.isArray(list)) return list.join(', ');
		} catch {
			/* show the stored text */
		}
	}
	return String(value);
}

export function createEditorLinks(request: LinkRequest): EditorLinks {
	let queued: { table: string; id: string; resolve(label: MentionLabel): void; reject(e: unknown): void }[] = [];
	async function tables() {
		const catalog = await request('catalog', {});
		return catalog.tables
			.filter((t) => typeof t.display === 'string' && !t.readOnly)
			.map((t) => ({ id: String(t.id), command: singular(String(t.id)) }));
	}
	return {
		tables,
		async search(table, text) {
			if (!text.trim()) return [];
			const [hits, allowed] = await Promise.all([
				request('search', { text, ...(table ? { table } : {}), limit: 20 }),
				tables()
			]);
			const ids = new Set(allowed.map((t) => t.id));
			return hits.filter((h) => ids.has(h.table)).map(({ table, id, label }) => ({ table, id, label }));
		},
		async views() {
			const list = await request('listViews', {});
			return list.views.filter((v) => !v.unavailable).map((v) => ({ table: v.tbl, id: v.id, name: v.name }));
		},
		label(table, id) {
			return new Promise((resolve, reject) => {
				// A document's mentions render together; resolve them in one request.
				if (!queued.length)
					queueMicrotask(async () => {
						const batch = queued;
						queued = [];
						for (let start = 0; start < batch.length; start += 200) {
							const chunk = batch.slice(start, start + 200);
							try {
								const labels = await request('mentionLabels', {
									targets: chunk.map(({ table, id }) => ({ table, id }))
								});
								chunk.forEach((item, index) => item.resolve(labels[index]));
							} catch (error) {
								for (const item of chunk) item.reject(error);
							}
						}
					});
				queued.push({ table, id, resolve, reject });
			});
		},
		async embed(table, viewId) {
			const first = await request('viewEmbed', { table, viewId });
			if (!first.calendar) return first;
			const { timeZone, dayStartMinutes } = first.calendar;
			return request('viewEmbed', { table, viewId, calendar: calendarContext(timeZone, new Date(), dayStartMinutes) });
		}
	};
}
