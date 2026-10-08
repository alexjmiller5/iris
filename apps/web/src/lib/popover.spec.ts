import { afterEach, expect, test } from 'vitest';
import { Window, type HTMLElement } from 'happy-dom';
import { focusReturn } from './popover';

const globals = globalThis as Record<string, unknown>;
afterEach(() => {
	delete globals.document;
	delete globals.HTMLElement;
});

test('a modal that unmounts hands focus back to its opener only when focus was dropped', () => {
	const window = new Window();
	const doc = window.document;
	Object.assign(globals, { document: doc, HTMLElement: window.HTMLElement });
	doc.body.innerHTML =
		'<button id="opener">Open</button><div id="modal"><input id="inside" /></div><button id="other">Other</button>';
	(doc.getElementById('opener') as unknown as HTMLElement).focus();
	const restore = focusReturn();
	(doc.getElementById('inside') as unknown as HTMLElement).focus();
	doc.getElementById('modal')!.remove();
	expect(doc.activeElement).toBe(doc.body);
	restore();
	expect(doc.activeElement?.id).toBe('opener');

	// A destination that took focus on purpose keeps it.
	const keep = focusReturn();
	(doc.getElementById('other') as unknown as HTMLElement).focus();
	keep();
	expect(doc.activeElement?.id).toBe('other');
	window.happyDOM.abort();
});
