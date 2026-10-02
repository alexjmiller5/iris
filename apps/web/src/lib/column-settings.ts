import type { Property } from 'life-ui-core/client';

export function visibleColumns(
	properties: readonly Property[],
	columns: readonly string[]
): string[] {
	const available = new Set(properties.map((property) => property.col));
	return [...new Set(columns)].filter((col) => available.has(col));
}

export function toggleColumn(columns: readonly string[], col: string, shown: boolean): string[] {
	return shown ? [...new Set([...columns, col])] : columns.filter((column) => column !== col);
}

export function moveColumn(columns: readonly string[], col: string, direction: -1 | 1): string[] {
	const result = [...columns];
	const index = result.indexOf(col);
	const next = index + direction;
	if (index >= 0 && next >= 0 && next < result.length) {
		[result[index], result[next]] = [result[next], result[index]];
	}
	return result;
}

export function changeWidth(
	widths: Readonly<Record<string, number>>,
	col: string,
	value: string
): Record<string, number> | null {
	if (!value.trim()) {
		const result = { ...widths };
		delete result[col];
		return result;
	}
	const number = Number(value);
	if (!Number.isFinite(number)) return null;
	return { ...widths, [col]: Math.min(800, Math.max(96, Math.round(number))) };
}
