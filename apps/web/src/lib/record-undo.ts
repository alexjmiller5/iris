export function reconcileUndo(
	values: Readonly<Record<string, string>>,
	before: Readonly<Record<string, string>>,
	after: Readonly<Record<string, string>>
) {
	const columns = Object.keys(values);
	const baseline = Object.fromEntries(columns.map((column) => [column, after[column] ?? '']));
	const next = Object.fromEntries(
		columns.map((column) => [
			column,
			values[column] === (before[column] ?? '') ? baseline[column] : values[column]
		])
	);
	return {
		values: next,
		baseline: JSON.stringify(baseline),
		dirty: columns.some((column) => next[column] !== baseline[column])
	};
}
