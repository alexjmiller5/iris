import { OPTION_COLORS, type OptionDef, type Property } from 'iris-core/client';

export type OptionColor = NonNullable<OptionDef['color']>;

/** The catalog's palette color for one value; anything else renders neutral. */
export function optionColor(
	property: Pick<Property, 'options'>,
	value: string
): OptionColor | null {
	const color = property.options?.find((o) => o.v === value)?.color;
	return color && (OPTION_COLORS as readonly string[]).includes(color) ? color : null;
}

/** Stored select or multi-select source as display values; malformed lists show none. */
export function selectValues(property: Pick<Property, 'type'>, value: unknown): string[] {
	if (value == null || value === '') return [];
	if (property.type === 'select') return [String(value)];
	if (property.type !== 'multi_select') return [];
	try {
		const values = JSON.parse(String(value));
		return Array.isArray(values) ? values.map(String) : [];
	} catch {
		return [];
	}
}

/** A new option's starting color: the palette in order, skipping default. */
export function newOptionColor(index: number): OptionColor {
	const palette = OPTION_COLORS.slice(1);
	return palette[index % palette.length];
}

/** Customizable selects can render chips inside options. */
export function richSelect(): boolean {
	return typeof CSS !== 'undefined' && CSS.supports('appearance', 'base-select');
}
