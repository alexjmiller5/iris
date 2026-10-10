import { readFileSync } from 'node:fs';
import { expect, test } from 'vitest';
import { OPTION_COLORS } from 'iris-core/client';

// Every chip tint keeps chip text at WCAG AA (4.5:1) in light and dark.
const css = readFileSync(new URL('../theme.css', import.meta.url), 'utf8');
const [light, dark] = css.split('@media (prefers-color-scheme: dark)');
const token = (block: string, name: string) => {
	const hex = new RegExp(`--color-option-${name}:\\s*(#[0-9a-f]{6})`).exec(block)?.[1];
	if (!hex) throw new Error(`missing --color-option-${name}`);
	return hex;
};
const luminance = (hex: string) => {
	const [r, g, b] = [1, 3, 5].map((i) => {
		const c = parseInt(hex.slice(i, i + 2), 16) / 255;
		return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
	});
	return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
const contrast = (a: string, b: string) => {
	const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
	return (hi + 0.05) / (lo + 0.05);
};

test.each([
	['light', light],
	['dark', dark]
])('%s chip tints keep text legible', (_, block) => {
	const ink = token(block, 'ink');
	for (const color of OPTION_COLORS)
		expect(contrast(ink, token(block, color))).toBeGreaterThanOrEqual(4.5);
});
