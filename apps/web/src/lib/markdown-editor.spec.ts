// @vitest-environment happy-dom
import { afterEach, expect, test, vi } from 'vitest';
import { createMarkdownEditor, type MarkdownController } from './markdown-editor';
import { irisHref } from 'iris-core/client';

const editors: MarkdownController[] = [];
test('a late image response is disposed after its source node leaves the document', async () => {
	const element = document.createElement('div');
	document.body.appendChild(element);
	let release!: (file: { url: string; contentType: string; dispose(): void }) => void;
	const pending = new Promise<{ url: string; contentType: string; dispose(): void }>(
		(resolve) => (release = resolve)
	);
	const editor = await createMarkdownEditor(element, {
		value: '![Diagram](/v1/files/raw/a.png)',
		label: 'Body',
		id: 'late',
		onchange() {},
		resolveFile: () => pending
	});
	editors.push(editor);
	editor.replaceMarkdown('Other document');
	const dispose = vi.fn();
	release({ url: 'blob:late', contentType: 'image/png', dispose });
	await vi.waitFor(() => expect(dispose).toHaveBeenCalledTimes(1));
	expect(element.querySelector('img[src]')).toBeNull();
	expect(editor.getMarkdown()).toBe('Other document');
});
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
test('retained images render through the host without editing their original Markdown', async () => {
	const element = document.createElement('div');
	document.body.appendChild(element);
	const source =
		'![Diagram](/v1/files/raw/diagram.png)\n\n![Remote](https://expired.example/image.png)\n';
	const dispose = vi.fn(),
		onchange = vi.fn();
	const resolveFile = vi.fn(async () => ({
		url: 'blob:fixture-image',
		contentType: 'image/png',
		dispose
	}));
	const editor = await createMarkdownEditor(element, {
		value: source,
		label: 'Body',
		id: 'files',
		onchange,
		resolveFile
	});
	editors.push(editor);
	await vi.waitFor(() =>
		expect(element.querySelector('img[src]')?.getAttribute('src')).toBe('blob:fixture-image')
	);
	expect(resolveFile).toHaveBeenCalledTimes(1);
	expect(resolveFile).toHaveBeenCalledWith('raw/diagram.png', expect.any(AbortSignal), true);
	expect(editor.getMarkdown()).toBe(source);
	expect(onchange).not.toHaveBeenCalled();
	editor.replaceMarkdown('Removed');
	expect(dispose).toHaveBeenCalledTimes(1);
});
test('retained image failures show retry, and a retry leaves source unchanged', async () => {
	const element = document.createElement('div');
	document.body.appendChild(element);
	const source = '![Diagram](/v1/files/raw/a.png)';
	const resolveFile = vi
		.fn()
		.mockRejectedValueOnce(Error('File HTTP 404'))
		.mockResolvedValue({ url: 'blob:retry', contentType: 'image/png', dispose: vi.fn() });
	const onchange = vi.fn();
	const editor = await createMarkdownEditor(element, {
		value: source,
		label: 'Body',
		id: 'retry',
		onchange,
		resolveFile
	});
	editors.push(editor);
	await vi.waitFor(() => expect(element.textContent).toContain('File HTTP 404'));
	(element.querySelector('button') as HTMLButtonElement).click();
	await vi.waitFor(() =>
		expect(element.querySelector('img[src]')?.getAttribute('src')).toBe('blob:retry')
	);
	expect(editor.getMarkdown()).toBe(source);
	expect(onchange).not.toHaveBeenCalled();
});
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

test.each([
	'[Related record](https://source.invalid/record)',
	'[![Diagram](/v1/files/raw/image.png)](https://source.invalid/record)'
])(
	'read-only links expose their clicked anchor without navigating or modifying %s',
	async (source) => {
		const element = document.createElement('div');
		document.body.appendChild(element);
		let destination: string | undefined;
		let anchor: Element | undefined;
		const editor = await createMarkdownEditor(element, {
			value: source,
			label: 'Body',
			id: 'link-anchor',
			onchange() {},
			onopenlink(href, node) {
				destination = href;
				anchor = node;
			}
		});
		editors.push(editor);
		editor.setReadOnly(true);
		const link = element.querySelector('a')!;
		const event = new MouseEvent('click', { bubbles: true, cancelable: true });
		(link.querySelector('[data-type]') ?? link).dispatchEvent(event);
		expect(event.defaultPrevented).toBe(true);
		expect(destination).toBe('https://source.invalid/record');
		expect(anchor).toBe(link);
		expect(editor.getMarkdown()).toBe(source);
	}
);

const mentionHref = irisHref('row', 'people', 'p(1)');
const viewHref = irisHref('view', 'items', 'v1');
function linkHost(label: string | null = 'Ada Lovelace', trashed = false) {
	return {
		label: vi.fn(async (table: string, id: string) => ({ table, id, label, trashed })),
		embed: vi.fn(async () => ({
			name: 'Open items',
			more: true,
			columns: [
				{ column: 'name', label: 'Name', type: 'text' },
				{ column: 'done', label: 'Done', type: 'bool' }
			],
			rows: [{ record: { id: 'a', name: 'Alpha', done: 1 }, label: 'Alpha' }]
		}))
	};
}
async function openLinked(value: string, links = linkHost(), onopenrecord = vi.fn()) {
	const element = document.createElement('div');
	document.body.appendChild(element);
	const onchange = vi.fn();
	const editor = await createMarkdownEditor(element, {
		value,
		label: 'Body',
		id: 'links',
		onchange,
		links,
		onopenrecord
	});
	editors.push(editor);
	return { editor, element, onchange, onopenrecord, links };
}

test('mentions show the live display label and open the record without rewriting Markdown', async () => {
	const source = `Met [Ada](${mentionHref}) today.\n`;
	const { editor, element, onchange, onopenrecord, links } = await openLinked(source);
	const mention = await vi.waitFor(() => {
		const button = element.querySelector<HTMLButtonElement>('button.iris-mention')!;
		expect(button.textContent).toBe('Ada Lovelace');
		return button;
	});
	expect(links.label).toHaveBeenCalledWith('people', 'p(1)');
	expect(mention.dataset.state).toBe('live');
	mention.click();
	expect(onopenrecord).toHaveBeenCalledWith(mentionHref, mention);
	expect(onchange).not.toHaveBeenCalled();
	expect(editor.getMarkdown()).toBe(source);
});

test('missing or trashed mention targets keep the stored text and say why', async () => {
	const { element } = await openLinked(`[Ada](${mentionHref})`, linkHost(null));
	await vi.waitFor(() =>
		expect(element.querySelector('.iris-mention')!.getAttribute('data-state')).toBe('unavailable')
	);
	expect(element.querySelector('.iris-mention')!.textContent).toBe('Ada (unavailable)');
	const trashed = await openLinked(`[Ada](${mentionHref})`, linkHost('Ada Lovelace', true));
	await vi.waitFor(() =>
		expect(trashed.element.querySelectorAll('.iris-mention')[0].textContent).toBe(
			'Ada Lovelace (in trash)'
		)
	);
});

test('view links embed a read-only preview of the saved view with an open action', async () => {
	const source = `Intro\n\n[Items](${viewHref})\n`;
	const { editor, element, onopenrecord, onchange } = await openLinked(source);
	const embed = await vi.waitFor(() => {
		const node = element.querySelector<HTMLElement>('.iris-embed')!;
		expect(node.querySelector('table')).not.toBeNull();
		return node;
	});
	expect(embed.querySelector('.iris-embed-title')!.textContent).toBe('Open items');
	expect([...embed.querySelectorAll('th')].map((th) => th.textContent)).toEqual(['Name', 'Done']);
	expect([...embed.querySelectorAll('td')].map((td) => td.textContent)).toEqual(['Alpha', 'Yes']);
	expect(embed.textContent).toContain('More rows in the view');
	embed.querySelector<HTMLButtonElement>('button')!.click();
	expect(onopenrecord).toHaveBeenCalledWith(viewHref, expect.any(HTMLButtonElement));
	expect(onchange).not.toHaveBeenCalled();
	expect(editor.getMarkdown()).toBe(source);
});

test('inserted mentions and view embeds are stored as plain Markdown links', async () => {
	const { editor } = await openLinked('');
	expect(editor.insertLink(mentionHref, 'Ada Lovelace')).toBe(true);
	expect(editor.getMarkdown()).toBe(`[Ada Lovelace](${mentionHref})\n`);
	editor.replaceMarkdown('');
	expect(editor.insertLink(viewHref, 'Open items')).toBe(true);
	expect(editor.getMarkdown()).toBe(`[Open items](${viewHref})\n`);
});

test('mentions survive edits elsewhere in the document', async () => {
	const { editor } = await openLinked(`Met [Ada](${mentionHref}) today.`);
	editor.command('heading1');
	expect(editor.getMarkdown()).toBe(`# Met [Ada](${mentionHref}) today.\n`);
});
