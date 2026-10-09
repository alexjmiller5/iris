import {
	Editor,
	defaultValueCtx,
	editorViewCtx,
	editorViewOptionsCtx,
	rootCtx,
	serializerCtx
} from '@milkdown/kit/core';
import {
	commonmark,
	imageSchema,
	turnIntoTextCommand,
	wrapInHeadingCommand,
	wrapInBulletListCommand,
	wrapInOrderedListCommand,
	wrapInBlockquoteCommand,
	createCodeBlockCommand,
	toggleStrongCommand,
	toggleEmphasisCommand,
	toggleInlineCodeCommand,
	toggleLinkCommand
} from '@milkdown/kit/preset/commonmark';
import { gfm, insertTableCommand } from '@milkdown/kit/preset/gfm';
import { history, undoCommand, redoCommand } from '@milkdown/kit/plugin/history';
import { Plugin, TextSelection } from '@milkdown/kit/prose/state';
import { undoInputRule } from '@milkdown/kit/prose/inputrules';
import { $prose, callCommand, replaceAll } from '@milkdown/kit/utils';
import { retainedImage } from './retained-image';
import { irisLinkSchema, irisLinkView } from './iris-link';
import type { EditorLinks } from './editor-links';
import type { RetainedFileResolver } from './retained-files';
import { parseIrisHref } from 'iris-core/client';

export type MarkdownCommand =
	| 'paragraph'
	| 'heading1'
	| 'heading2'
	| 'heading3'
	| 'bullet'
	| 'ordered'
	| 'quote'
	| 'codeBlock'
	| 'task'
	| 'table'
	| 'undo'
	| 'redo'
	| 'bold'
	| 'italic'
	| 'inlineCode'
	| 'link';
export interface MarkdownController {
	getMarkdown(): string;
	focus(): void;
	replaceMarkdown(value: string): void;
	command(command: MarkdownCommand, value?: string): boolean;
	/** Insert a mention (inline) or a view embed (its own line) at the selection. */
	insertLink(href: string, label: string): boolean;
	setReadOnly(value: boolean): void;
	destroy(): Promise<void>;
}
export async function createMarkdownEditor(
	element: HTMLElement,
	options: {
		value: string;
		label: string;
		id: string;
		onchange(value: string): void;
		onslash?(): void;
		resolveFile?: RetainedFileResolver;
		onopenlink?(href: string, anchor: HTMLAnchorElement): void;
		links?: Pick<EditorLinks, 'label' | 'embed'>;
		onopenrecord?(href: string, element: HTMLElement): void;
	}
): Promise<MarkdownController> {
	let source = options.value;
	let replacing = false;
	let readOnly = false;
	let destroyed = false;
	const changes = $prose(
		(ctx) =>
			new Plugin({
				view: () => ({
					update(view, previous) {
						if (destroyed || replacing || view.state.doc.eq(previous.doc)) return;
						const updated = ctx.get(serializerCtx)(view.state.doc);
						if (updated === source) return;
						source = updated;
						options.onchange(source);
					}
				})
			})
	);
	const editor = await Editor.make()
		.config((ctx) => {
			ctx.set(rootCtx, element);
			ctx.set(defaultValueCtx, source);
			// Retain image references without fetching remote content while editing.
			ctx.update(imageSchema.key, (previous) => (context) => {
				const schema = previous(context);
				return {
					...schema,
					attrs: { ...schema.attrs, title: { default: null, validate: 'string|null' } },
					toDOM: (node) => [
						'span',
						{
							'data-type': 'image-reference',
							role: 'img',
							'aria-label': node.attrs.alt || 'Image reference'
						},
						node.attrs.alt || 'Image reference'
					]
				};
			});
			ctx.set(editorViewOptionsCtx, {
				editable: () => !readOnly,
				handleKeyDown(view, event) {
					if (
						!readOnly &&
						(event.metaKey || event.ctrlKey) &&
						!event.shiftKey &&
						!event.altKey &&
						event.key.toLowerCase() === 'z' &&
						undoInputRule(view.state, view.dispatch)
					) {
						event.preventDefault();
						return true;
					}
					const { empty, $from } = view.state.selection;
					if (
						!readOnly &&
						event.key === '/' &&
						empty &&
						['paragraph', 'heading'].includes($from.parent.type.name) &&
						!$from.parent.content.size &&
						options.onslash
					) {
						event.preventDefault();
						options.onslash();
						return true;
					}
					return false;
				},
				handleTextInput(view, from, to, text) {
					if (
						!readOnly &&
						text === '/' &&
						from === to &&
						['paragraph', 'heading'].includes(view.state.selection.$from.parent.type.name) &&
						!view.state.selection.$from.parent.content.size &&
						options.onslash
					) {
						options.onslash();
						return true;
					}
					return false;
				},
				nodeViews: {
					image: (node) => retainedImage(node, options.resolveFile),
					iris_link: (node) => irisLinkView(node, options.links, options.onopenrecord),
					list_item(node, view, getPos) {
						const dom = document.createElement('li');
						const contentDOM = document.createElement('div');
						const checkbox = document.createElement('input');
						checkbox.type = 'checkbox';
						checkbox.contentEditable = 'false';
						checkbox.setAttribute('aria-label', 'Completed task');
						dom.appendChild(checkbox);
						dom.appendChild(contentDOM);
						const update = (next: typeof node) => {
							if (next.type !== node.type) return false;
							node = next;
							checkbox.hidden = node.attrs.checked == null;
							checkbox.checked = node.attrs.checked === true;
							checkbox.disabled = readOnly;
							if (node.attrs.checked != null) dom.dataset.itemType = 'task';
							else delete dom.dataset.itemType;
							return true;
						};
						update(node);
						checkbox.onchange = () => {
							const pos = getPos();
							if (!readOnly && pos !== undefined)
								view.dispatch(
									view.state.tr.setNodeMarkup(pos, undefined, {
										...node.attrs,
										checked: checkbox.checked
									})
								);
						};
						return {
							dom,
							contentDOM,
							update,
							stopEvent: (event) => event.target === checkbox,
							ignoreMutation: (mutation) =>
								mutation.type !== 'selection' && mutation.target === checkbox
						};
					}
				},
				attributes: {
					id: options.id,
					role: 'textbox',
					'aria-label': options.label,
					'aria-multiline': 'true'
				},
				handleDOMEvents: {
					click: (_view, event) => {
						const link = (event.target as Element).closest('a');
						if (link) {
							event.preventDefault();
							const href = link.getAttribute('href');
							if (href) options.onopenlink?.(href, link);
							return true;
						}
						return false;
					}
				}
			});
		})
		.use(commonmark)
		.use(gfm)
		.use(irisLinkSchema)
		.use(history)
		.use(changes)
		.create();
	return {
		getMarkdown: () => source,
		focus() {
			if (!destroyed) editor.action((ctx) => ctx.get(editorViewCtx).focus());
		},
		replaceMarkdown(value) {
			if (destroyed || value === source) return;
			replacing = true;
			try {
				editor.action(replaceAll(value));
				editor.action((ctx) => {
					const view = ctx.get(editorViewCtx);
					view.dispatch(view.state.tr.setSelection(TextSelection.atStart(view.state.doc)));
				});
				source = value;
			} finally {
				replacing = false;
			}
		},
		command(command, value) {
			if (readOnly || destroyed) return false;
			let result = false;
			switch (command) {
				case 'paragraph':
					result = editor.action(callCommand(turnIntoTextCommand.key));
					break;
				case 'heading1':
				case 'heading2':
				case 'heading3':
					result = editor.action(callCommand(wrapInHeadingCommand.key, Number(command.at(-1))));
					break;
				case 'italic':
					result = editor.action(callCommand(toggleEmphasisCommand.key));
					break;
				case 'inlineCode':
					result = editor.action(callCommand(toggleInlineCodeCommand.key));
					break;
				case 'link':
					result =
						typeof value === 'string' &&
						/^(https?:|mailto:|tel:|#|\/)/i.test(value) &&
						editor.action(callCommand(toggleLinkCommand.key, { href: value }));
					break;
				case 'bold':
					result = editor.action(callCommand(toggleStrongCommand.key));
					break;
				case 'bullet':
					result = editor.action(callCommand(wrapInBulletListCommand.key));
					break;
				case 'ordered':
					result = editor.action(callCommand(wrapInOrderedListCommand.key));
					break;
				case 'quote':
					result = editor.action(callCommand(wrapInBlockquoteCommand.key));
					break;
				case 'codeBlock':
					result = editor.action(callCommand(createCodeBlockCommand.key));
					break;
				case 'table':
					result = editor.action(callCommand(insertTableCommand.key, { row: 2, col: 2 }));
					break;
				case 'undo':
					result =
						editor.action((ctx) => {
							const view = ctx.get(editorViewCtx);
							return undoInputRule(view.state, view.dispatch);
						}) || editor.action(callCommand(undoCommand.key));
					break;
				case 'redo':
					result = editor.action(callCommand(redoCommand.key));
					break;
				case 'task': {
					editor.action(callCommand(wrapInBulletListCommand.key));
					result = editor.action((ctx) => {
						const view = ctx.get(editorViewCtx);
						const { $from } = view.state.selection;
						for (let depth = $from.depth; depth > 0; depth--) {
							const node = $from.node(depth);
							if (node.type.name === 'list_item') {
								view.dispatch(
									view.state.tr.setNodeMarkup($from.before(depth), undefined, {
										...node.attrs,
										checked: false
									})
								);
								return true;
							}
						}
						return false;
					});
				}
			}
			editor.action((ctx) => ctx.get(editorViewCtx).focus());
			return result;
		},
		insertLink(href, label) {
			const link = parseIrisHref(href);
			if (readOnly || destroyed || !link) return false;
			return editor.action((ctx) => {
				const view = ctx.get(editorViewCtx);
				let tr = view.state.tr.replaceSelectionWith(
					irisLinkSchema.type(ctx).create({ href, label }),
					false
				);
				if (
					link.kind === 'view' &&
					tr.selection.$to.depth === 1 &&
					tr.selection.$to.after() === tr.doc.content.size
				) {
					// An embed sits on its own line; leave somewhere to keep typing.
					const after = tr.selection.$to.after();
					tr = tr.insert(after, view.state.schema.nodes.paragraph.create());
					tr = tr.setSelection(TextSelection.create(tr.doc, after + 1));
				}
				view.dispatch(tr.scrollIntoView());
				view.focus();
				return true;
			});
		},
		setReadOnly(value) {
			readOnly = value;
			if (!destroyed) {
				editor.action((ctx) => ctx.get(editorViewCtx).setProps({ editable: () => !readOnly }));
				for (const checkbox of element.querySelectorAll<HTMLInputElement>('input[type=checkbox]'))
					checkbox.disabled = readOnly;
			}
		},
		async destroy() {
			destroyed = true;
			await editor.destroy();
		}
	};
}
