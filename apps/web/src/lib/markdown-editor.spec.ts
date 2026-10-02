// @vitest-environment happy-dom
import { afterEach, expect, test, vi } from 'vitest';
import { createMarkdownEditor, type MarkdownController } from './markdown-editor';

const editors: MarkdownController[] = [];
afterEach(async () => {
	for (const editor of editors.splice(0)) await editor.destroy();
	document.body.replaceChildren();
});
async function open(value: string, onchange = (_value: string) => {}) {
	const element = document.createElement('div');
	document.body.appendChild(element);
	const editor = await createMarkdownEditor(element, {
		value,
		label: 'Body',
		id: 'body',
		onchange
	});
	editors.push(editor);
	return { editor, element };
}
test('opening Markdown renders a heading and keeps the untouched source bytes', async () => {
	const source = '# A heading\n\n**Bold** and _italic_.\n';
	const { editor, element } = await open(source);
	expect(element.querySelector('h1')?.textContent).toBe('A heading');
	expect(element.querySelector('strong')?.textContent).toBe('Bold');
	expect(editor.getMarkdown()).toBe(source);
});
test('formatting changes the document and reports plain Markdown', async () => {
	const values: string[] = [];
	const { editor, element } = await open('A paragraph', (value) => values.push(value));
	expect(editor.command('heading1')).toBe(true);
	expect(element.querySelector('h1')?.textContent).toBe('A paragraph');
	await vi.waitFor(() => expect(values).toEqual(['# A paragraph\n']));
	expect(editor.getMarkdown()).toBe('# A paragraph\n');
});
test('source replacement preserves unknown blocks without emitting a user edit', async () => {
	const values: string[] = [];
	const { editor, element } = await open('Before', (value) => values.push(value));
	const source = '<mention-page url="https://example.com/page"/>\n\n# After\n';
	editor.replaceMarkdown(source);
	expect(element.querySelector('h1')?.textContent).toBe('After');
	expect(editor.getMarkdown()).toBe(source);
	expect(values).toEqual([]);
});
test('read-only state prevents formatting and disables the document', async () => {
	const { editor, element } = await open('Leave this text');
	editor.setReadOnly(true);
	expect(element.querySelector('[role="textbox"]')?.getAttribute('contenteditable')).toBe('false');
	expect(editor.command('heading1')).toBe(false);
	expect(editor.getMarkdown()).toBe('Leave this text');
});
test('HTML stays inert and image references do not create network-loading elements', async () => {
	const source =
		'<script>window.unsafe=true</script>\n\n![Retained image](https://example.com/private.png)\n';
	const { editor, element } = await open(source);
	expect(element.querySelectorAll('script,iframe,img[src],object,embed')).toHaveLength(0);
	expect(element.textContent).toContain('Retained image');
	expect(editor.getMarkdown()).toBe(source);
});

test.each([
	['heading2', 'h2', '## A paragraph\n'],
	['heading3', 'h3', '### A paragraph\n'],
	['bullet', 'ul', '* A paragraph\n'],
	['ordered', 'ol', '1. A paragraph\n'],
	['quote', 'blockquote', '> A paragraph\n'],
	['codeBlock', 'pre', '```\nA paragraph\n```\n'],
	['task', 'li[data-item-type="task"]', '* [ ] A paragraph\n']
] as const)(
	'%s formats the current block and returns its Markdown',
	async (command, selector, expected) => {
		const { editor, element } = await open('A paragraph');
		expect(editor.command(command)).toBe(true);
		expect(element.querySelector(selector)?.textContent).toBe('A paragraph');
		expect(editor.getMarkdown()).toBe(expected);
	}
);
test('undo and redo restore the actual document', async () => {
	const { editor, element } = await open('A paragraph');
	editor.command('heading1');
	expect(editor.command('undo')).toBe(true);
	expect(element.querySelector('h1')).toBeNull();
	expect(editor.getMarkdown()).toBe('A paragraph\n');
	expect(editor.command('redo')).toBe(true);
	expect(element.querySelector('h1')?.textContent).toBe('A paragraph');
});
test('table insertion provides editable header and body cells', async () => {
	const { editor, element } = await open('');
	expect(editor.command('table')).toBe(true);
	expect(element.querySelectorAll('th')).toHaveLength(2);
	expect(element.querySelectorAll('td')).toHaveLength(2);
	expect(editor.getMarkdown()).toContain('|');
});
test('a task checkbox updates the saved Markdown immediately', async () => {
	const values: string[] = [];
	const { editor, element } = await open('- [ ] A task\n', (value) => values.push(value));
	const checkbox = element.querySelector<HTMLInputElement>('input[type=checkbox]');
	expect(checkbox).not.toBeNull();
	checkbox!.click();
	expect(editor.getMarkdown()).toBe('* [x] A task\n');
	expect(values.at(-1)).toBe('* [x] A task\n');
	editor.setReadOnly(true);
	expect(checkbox!.disabled).toBe(true);
});

test('slash on an empty paragraph opens the block chooser without inserting text', async () => {
	const element = document.createElement('div');
	document.body.appendChild(element);
	let choicesOpened = 0;
	const editor = await createMarkdownEditor(element, {
		value: '',
		label: 'Body',
		id: 'slash',
		onchange() {},
		onslash() {
			choicesOpened++;
		}
	});
	editors.push(editor);
	const event = new KeyboardEvent('keydown', { key: '/', bubbles: true, cancelable: true });
	element.querySelector('[role=textbox]')!.dispatchEvent(event);
	expect(choicesOpened).toBe(1);
	expect(event.defaultPrevented).toBe(true);
	expect(editor.getMarkdown()).toBe('');
	editor.replaceMarkdown('Existing paragraph');
	element
		.querySelector('[role=textbox]')!
		.dispatchEvent(new KeyboardEvent('keydown', { key: '/', bubbles: true, cancelable: true }));
	expect(choicesOpened).toBe(1);
});

test('replacing a selected document with empty source leaves an insertion cursor for slash', async () => {
	const element = document.createElement('div');
	document.body.appendChild(element);
	let choicesOpened = 0;
	const editor = await createMarkdownEditor(element, {
		value: 'Selected text',
		label: 'Body',
		id: 'replace',
		onchange() {},
		onslash() {
			choicesOpened++;
		}
	});
	editors.push(editor);
	const textbox = element.querySelector('[role=textbox]')!;
	textbox.dispatchEvent(
		new KeyboardEvent('keydown', {
			key: 'a',
			keyCode: 65,
			ctrlKey: true,
			bubbles: true,
			cancelable: true
		})
	);
	editor.replaceMarkdown('');
	textbox.dispatchEvent(
		new KeyboardEvent('keydown', { key: '/', bubbles: true, cancelable: true })
	);
	expect(choicesOpened).toBe(1);
});
