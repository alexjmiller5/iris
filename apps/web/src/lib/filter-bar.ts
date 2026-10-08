import type { Filter, FilterGroup } from 'life-ui-core/client';

/** One filter chip as the person edits it. Values stay raw text until they
 * parse; several values are "any of" (or "none of" for `ne`). */
export type Rule = { column: string; op: Filter['op']; values: string[]; relative?: 'today' };
export type FilterState = { filters: Filter[]; groups: FilterGroup[] };
export type ChipRef = { kind: 'filter' | 'group'; index: number };
/** A null rule is an advanced group, edited rule by rule. */
export type Chip = { ref: ChipRef; rule: Rule | null };
export type GroupDraft = { match: FilterGroup['match']; rules: Rule[] };

export const DATE_TYPES = ['date', 'datetime', 'date_or_datetime'];
const ORDERED: Filter['op'][] = ['eq', 'ne', 'lt', 'gt', 'lte', 'gte', 'empty', 'not_empty'];

export function operatorsFor(type: string): Filter['op'][] {
	if (type === 'bool') return ['eq'];
	if (type === 'select' || type === 'ref') return ['eq', 'ne', 'empty', 'not_empty'];
	if (type === 'multi_select' || type === 'multi_ref') return ['contains', 'empty', 'not_empty'];
	if (['number', 'int', ...DATE_TYPES].includes(type)) return ORDERED;
	return ['contains', 'eq', 'ne', 'empty', 'not_empty'];
}

export function opLabel(op: Filter['op'], type: string): string {
	if (op === 'empty') return 'is empty';
	if (op === 'not_empty') return 'is not empty';
	if (DATE_TYPES.includes(type))
		return {
			eq: 'is',
			ne: 'is not',
			lt: 'is before',
			gt: 'is after',
			lte: 'is on or before',
			gte: 'is on or after',
			contains: 'contains'
		}[op];
	if (type === 'number' || type === 'int')
		return { eq: '=', ne: '≠', lt: '<', gt: '>', lte: '≤', gte: '≥', contains: 'contains' }[op];
	return { eq: 'is', ne: 'is not', contains: 'contains', lt: '<', gt: '>', lte: '≤', gte: '≥' }[
		op
	];
}

export function defaultRule(column: string, type: string): Rule {
	return { column, op: operatorsFor(type)[0], values: type === 'bool' ? ['true'] : [] };
}

const needsValue = (rule: Rule) => !['empty', 'not_empty'].includes(rule.op) && !rule.relative;

function parse(raw: string, type: string): Filter['value'] {
	if (type === 'number' || type === 'int') {
		if (!Number.isFinite(Number(raw))) throw new Error('Enter a number for this filter.');
		return Number(raw);
	}
	if (type === 'bool') return raw === 'true';
	return raw;
}

/** The saved clause for a rule, or null while it is incomplete. */
export function ruleClause(
	rule: Rule,
	type: string
): { clause: Filter | FilterGroup | null; error: string } {
	const { column, op } = rule;
	if (!needsValue(rule))
		return {
			clause: rule.relative && op !== 'empty' && op !== 'not_empty' ? { column, op, relative: 'today' } : { column, op },
			error: ''
		};
	try {
		const values = rule.values.filter((v) => v.trim() !== '').map((v) => parse(v, type));
		if (!values.length) return { clause: null, error: '' };
		if (values.length === 1) return { clause: { column, op, value: values[0] }, error: '' };
		return {
			clause: {
				match: op === 'ne' ? 'all' : 'any',
				filters: values.map((value) => ({ column, op, value }))
			},
			error: ''
		};
	} catch (e) {
		return { clause: null, error: (e as Error).message };
	}
}

function filterRule(filter: Filter): Rule {
	return {
		column: filter.column,
		op: filter.op,
		values: filter.value === undefined || filter.value === null ? [] : [String(filter.value)],
		...(filter.relative ? { relative: filter.relative } : {})
	};
}

/** Groups written by a multi-option chip read back as that chip. */
function groupRule(group: FilterGroup): Rule | null {
	const [first] = group.filters;
	if (
		group.filters.length < 2 ||
		group.match !== (first.op === 'ne' ? 'all' : 'any') ||
		!['eq', 'ne', 'contains'].includes(first.op) ||
		group.filters.some(
			(f) =>
				f.column !== first.column ||
				f.op !== first.op ||
				f.relative !== undefined ||
				f.value === undefined ||
				f.value === null
		)
	)
		return null;
	return { column: first.column, op: first.op, values: group.filters.map((f) => String(f.value)) };
}

export function chipsOf(state: FilterState): Chip[] {
	return [
		...state.filters.map((filter, index) => ({
			ref: { kind: 'filter' as const, index },
			rule: filterRule(filter)
		})),
		...state.groups.map((group, index) => ({
			ref: { kind: 'group' as const, index },
			rule: groupRule(group)
		}))
	];
}

/** Put a clause at ref (or append it), moving between filters and groups when
 * its shape changes. A null clause removes the chip's saved clause. */
function place(
	state: FilterState,
	ref: ChipRef | null,
	clause: Filter | FilterGroup | null
): { state: FilterState; ref: ChipRef | null } {
	if (!clause && !ref) return { state, ref: null };
	const filters = [...state.filters],
		groups = [...state.groups];
	const isGroup = !!clause && 'match' in clause;
	let next: ChipRef | null = null;
	if (ref?.kind === 'filter') {
		if (clause && !isGroup) {
			filters[ref.index] = clause as Filter;
			next = ref;
		} else filters.splice(ref.index, 1);
	} else if (ref?.kind === 'group') {
		if (isGroup) {
			groups[ref.index] = clause as FilterGroup;
			next = ref;
		} else groups.splice(ref.index, 1);
	}
	if (clause && !next) {
		if (isGroup) next = { kind: 'group', index: groups.push(clause as FilterGroup) - 1 };
		else next = { kind: 'filter', index: filters.push(clause as Filter) - 1 };
	}
	return { state: { filters, groups }, ref: next };
}

export function placeRule(
	state: FilterState,
	ref: ChipRef | null,
	rule: Rule,
	typeOf: (column: string) => string
): { state: FilterState; ref: ChipRef | null; error: string } {
	const { clause, error } = ruleClause(rule, typeOf(rule.column));
	if (error) return { state, ref, error };
	return { ...place(state, ref, clause), error: '' };
}

export function removeChip(state: FilterState, ref: ChipRef): FilterState {
	return place(state, ref, null).state;
}

export function groupDraft(group: FilterGroup): GroupDraft {
	return { match: group.match, rules: group.filters.map(filterRule) };
}

/** Advanced group rules each save as one filter; incomplete rules wait. */
export function placeGroup(
	state: FilterState,
	ref: ChipRef | null,
	draft: GroupDraft,
	typeOf: (column: string) => string
): { state: FilterState; ref: ChipRef | null } {
	const filters = draft.rules
		.map((rule) => ruleClause({ ...rule, values: rule.values.slice(0, 1) }, typeOf(rule.column)))
		.map((r) => r.clause)
		.filter((clause): clause is Filter => !!clause && !('match' in clause));
	return place(state, ref, filters.length ? { match: draft.match, filters } : null);
}

export function describeRule(
	rule: Rule,
	type: string,
	label: (column: string) => string,
	valueLabel: (value: string) => string = (value) => value
): string {
	const name = label(rule.column);
	if (!needsValue(rule)) {
		if (rule.op === 'empty' || rule.op === 'not_empty') return `${name}: ${opLabel(rule.op, type)}`;
		const op = opLabel(rule.op, type).replace(/^is /, '');
		return `${name}: ${op === 'is' ? '' : op + ' '}Today`;
	}
	const values = rule.values.filter((v) => v.trim() !== '');
	if (!values.length) return name;
	if (type === 'bool') return `${name}: ${values[0] === 'true' ? 'checked' : 'unchecked'}`;
	const text = values.map(valueLabel).join(', ');
	const plain = rule.op === 'contains' || (rule.op === 'eq' && type !== 'number' && type !== 'int');
	return plain ? `${name}: ${text}` : `${name}: ${opLabel(rule.op, type).replace(/^is /, '')} ${text}`;
}
