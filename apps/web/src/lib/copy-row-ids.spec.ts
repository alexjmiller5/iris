import { afterEach, expect, test, vi } from 'vitest';
import { copyRowIds, rowCopyIds } from './copy-row-ids';

afterEach(() => vi.unstubAllGlobals());
test('copies exact distinct row IDs on separate lines', async () => {
	const writeText = vi.fn(async (_text: string) => {});
	vi.stubGlobal('navigator', { clipboard: { writeText } });
	await copyRowIds(['opaque-a', 'opaque-b', 'opaque-a']);
	expect(writeText).toHaveBeenCalledWith('opaque-a\nopaque-b');
});
test('empty selection leaves the clipboard unchanged', async () => {
	const writeText = vi.fn();
	vi.stubGlobal('navigator', { clipboard: { writeText } });
	await copyRowIds([]);
	expect(writeText).not.toHaveBeenCalled();
});
test('clipboard refusal reaches the caller', async () => {
	vi.stubGlobal('navigator', {
		clipboard: {
			writeText: async () => {
				throw Error('Clipboard denied');
			}
		}
	});
	await expect(copyRowIds(['opaque-a'])).rejects.toThrow('Clipboard denied');
});

test('right-clicking a selected row copies the selection; other rows copy only themselves', () => {
	const selected = ['opaque-a', 'opaque-b'];
	expect(rowCopyIds('opaque-b', selected)).toEqual(selected);
	expect(rowCopyIds('opaque-c', selected)).toEqual(['opaque-c']);
	expect(rowCopyIds('opaque-c', [])).toEqual(['opaque-c']);
});
