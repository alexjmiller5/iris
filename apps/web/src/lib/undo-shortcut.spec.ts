import { describe, expect, it } from 'vitest';
import { savedUndoShortcut } from './undo-shortcut';

const key = (extra: Partial<KeyboardEvent> = {}) =>
	({
		key: 'z',
		metaKey: true,
		ctrlKey: false,
		shiftKey: false,
		altKey: false,
		defaultPrevented: false,
		isComposing: false,
		repeat: false,
		composedPath: () => [],
		...extra
	}) as KeyboardEvent;
describe('human saved-change undo shortcut', () => {
	it('handles Cmd-Z and Ctrl-Z outside typing controls', () => {
		expect(savedUndoShortcut(key())).toBe(true);
		expect(savedUndoShortcut(key({ metaKey: false, ctrlKey: true }))).toBe(true);
	});
	it.each(['input', 'textarea', 'select', 'contenteditable', 'nested-editable'])(
		'keeps %s native editing undo',
		(type) => {
			const element = {
				nodeType: 1,
				closest: (selector: string) =>
					selector.includes(type === 'nested-editable' ? 'contenteditable' : type) ? {} : null
			};
			expect(
				savedUndoShortcut(key({ composedPath: () => [element as unknown as EventTarget] }))
			).toBe(false);
		}
	);
	it('does not swallow redo, composition, handled events or plain typing', () => {
		for (const extra of [
			{ shiftKey: true },
			{ altKey: true },
			{ isComposing: true },
			{ defaultPrevented: true },
			{ metaKey: false },
			{ repeat: true },
			{ key: 'x' }
		])
			expect(savedUndoShortcut(key(extra))).toBe(false);
	});
});
