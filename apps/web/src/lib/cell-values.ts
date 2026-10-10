import type { Property } from 'iris-core/client';
import { selectValues } from './option-colors';

/** A Boolean property, or an int whose only catalog options are 0 and 1. */
export function isFlag(property: Pick<Property, 'type' | 'options'>): boolean {
	if (property.type === 'bool') return true;
	const options = property.options?.map((o) => o.v).sort();
	return (
		property.type === 'int' && options?.length === 2 && options[0] === '0' && options[1] === '1'
	);
}

/** Stored flag source as true/false; empty and anything else is null. */
export function flagValue(value: unknown): boolean | null {
	if (value === true || value === 1 || value === '1' || value === '1.0' || value === 'true')
		return true;
	if (value === false || value === 0 || value === '0' || value === '0.0' || value === 'false')
		return false;
	return null;
}

const scalar = (value: unknown) => ['string', 'number', 'boolean'].includes(typeof value);

function parse(value: unknown): { ok: true; value: unknown } | { ok: false } {
	try {
		return { ok: true, value: JSON.parse(String(value)) };
	} catch {
		return { ok: false };
	}
}

/** Values a cell shows as chips: selects, and json lists of plain values. */
export function chipValues(property: Pick<Property, 'type'>, value: unknown): string[] | null {
	if (property.type === 'select' || property.type === 'multi_select')
		return selectValues(property, value);
	if (property.type !== 'json' || value == null) return null;
	const parsed = parse(value);
	return parsed.ok && Array.isArray(parsed.value) && parsed.value.every(scalar)
		? parsed.value.map(String)
		: null;
}

/** Other json as readable text: objects as `key: value`, lists of records as a count. */
export function jsonText(value: unknown): string {
	const parsed = parse(value);
	if (!parsed.ok) return String(value);
	const json = parsed.value;
	if (Array.isArray(json))
		return json.every(scalar)
			? json.join(', ')
			: `${json.length} ${json.length === 1 ? 'item' : 'items'}`;
	if (json && typeof json === 'object')
		return Object.entries(json)
			.filter(([, v]) => v !== null)
			.map(([key, v]) => `${key}: ${scalar(v) ? v : JSON.stringify(v)}`)
			.join(', ');
	return json == null ? '' : String(json);
}

const entities: Record<string, string> = {
	amp: '&',
	lt: '<',
	gt: '>',
	quot: '"',
	apos: "'",
	'#39': "'",
	nbsp: ' '
};

/** Markdown source as one line of plain text: no syntax marks, tags, link targets or embeds. */
export function markdownPreview(source: string, limit = 280): string {
	const text = source
		.slice(0, 4096)
		.replace(/<!--[\s\S]*?-->/g, ' ')
		// Notion-flavored tags keep their inner text; inline ones (mention-*, span) add no space.
		.replace(/<\/?(?:mention-[\w-]+|span|a|b|i|u|s|em|strong|code|sup|sub)(?:\s[^<>]*)?\/?>/gi, '')
		.replace(/<\/?[a-z][\w-]*(?:\s[^<>]*)?\/?>/gi, ' ')
		.replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')
		.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
		.replace(/^\s*```.*$/gm, ' ')
		.replace(/^\s*(?:[-*_]\s*){3,}$/gm, ' ')
		.replace(/^\s*\|?(?:\s*:?-+:?\s*\|)+\s*:?-*:?\s*$/gm, ' ')
		.replace(/^\s*(?:#{1,6}|>+|[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/gm, '')
		.replace(/\|/g, ' ')
		.replace(/(\*\*|__|~~|`)(.+?)\1/g, '$2')
		.replace(/(^|[^\w*])[*_]([^*_\n]+)[*_](?=[^\w*]|$)/g, '$1$2')
		.replace(/&(#39|[a-z]+);/gi, (match, name: string) => entities[name.toLowerCase()] ?? match)
		.replace(/\s+/g, ' ')
		.trim();
	return text.length > limit ? text.slice(0, limit).trimEnd() + '…' : text;
}

const DATE = /^(\d{4})-(\d{2})-(\d{2})$/;
const DATETIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;

/** Dates and UTC timestamps as the native apps show them; anything else is null (keep the source). */
export function dateText(
	type: string | null | undefined,
	value: unknown,
	locale?: string
): string | null {
	const source = String(value);
	const day = DATE.exec(source);
	if (day && (type === 'date' || type === 'date_or_datetime')) {
		const date = new Date(Date.UTC(+day[1], +day[2] - 1, +day[3]));
		// Strict: 2024-02-30 would roll over to March, so it stays as stored.
		if (date.toISOString().slice(0, 10) !== source) return null;
		return new Intl.DateTimeFormat(locale, { dateStyle: 'medium', timeZone: 'UTC' }).format(date);
	}
	if (DATETIME.test(source) && (type === 'datetime' || type === 'date_or_datetime')) {
		const date = new Date(source);
		if (Number.isNaN(date.getTime())) return null;
		const text = new Intl.DateTimeFormat(locale, {
			dateStyle: 'medium',
			timeStyle: 'short',
			timeZone: 'UTC'
		}).format(date);
		return `${text} UTC`;
	}
	return null;
}
