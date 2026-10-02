import { expect, test } from 'vitest';
import { editRevision } from './record-revision';

test('keeps the exact opened revision for optimistic writes', () => {
	expect(editRevision({ updated_at: '2026-01-02T03:04:05.123Z' })).toBe('2026-01-02T03:04:05.123Z');
});
test.each([undefined, null, 0, {}, '', 'not-a-time', '2026-02-30T00:00:00.000Z'])(
	'refuses editing without a real revision (%j)',
	(updated_at) => {
		expect(() => editRevision({ updated_at })).toThrow(/revision/i);
	}
);
