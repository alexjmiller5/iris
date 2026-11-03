export async function copyRowIds(ids: readonly string[]): Promise<void> {
	if (ids.length) await navigator.clipboard.writeText([...new Set(ids)].join('\n'));
}

export function rowCopyIds(rowId: string, selected: readonly string[]): string[] {
	return selected.includes(rowId) ? [...selected] : [rowId];
}
