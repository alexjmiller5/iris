import type { CellValue } from './contract';

export function displayCell(value: CellValue | null): string {
	if (value === null) return 'Not recorded';
	if (value.type === 'null') return 'Empty (NULL)';
	if (value.type === 'text' && value.value === '') return 'Empty text';
	return String(value.value);
}
