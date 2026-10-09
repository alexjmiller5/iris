import type { Node } from '@milkdown/kit/prose/model';
import { $nodeSchema } from '@milkdown/kit/utils';
import { parseIrisHref } from 'iris-core/client';
import { cellText, type EditorLinks } from './editor-links';

type MdastNode = { type: string; url?: string; title?: string | null; value?: string; children?: MdastNode[] };
const plainText = (node: MdastNode): string => node.value ?? (node.children ?? []).map(plainText).join('');

/** Mentions and view embeds: an atom that is still a plain `[label](iris://...)`
 * link in Markdown. Milkdown matches nodes before marks, so only iris links leave
 * the ordinary link mark. The stored label is kept; the live one is presentation. */
export const irisLinkSchema = $nodeSchema('iris_link', () => ({
	inline: true,
	group: 'inline',
	atom: true,
	selectable: true,
	marks: '',
	attrs: {
		href: { validate: 'string' },
		label: { default: '', validate: 'string' },
		title: { default: null, validate: 'string|null' }
	},
	parseDOM: [
		{
			tag: 'span[data-iris-link]',
			getAttrs: (dom: HTMLElement) => ({
				href: dom.getAttribute('data-iris-link'),
				label: dom.getAttribute('data-label') ?? ''
			})
		}
	],
	toDOM: (node: Node) => [
		'span',
		{ 'data-iris-link': node.attrs.href, 'data-label': node.attrs.label },
		node.attrs.label
	],
	parseMarkdown: {
		match: (node: MdastNode) =>
			node.type === 'link' && typeof node.url === 'string' && parseIrisHref(node.url) !== null,
		runner: (state, node, type) => {
			const link = node as MdastNode;
			state.addNode(type, { href: link.url, label: plainText(link), title: link.title ?? null });
		}
	},
	toMarkdown: {
		match: (node: Node) => node.type.name === 'iris_link',
		runner: (state, node) => {
			state.openNode('link', undefined, { url: node.attrs.href, title: node.attrs.title });
			state.addNode('text', undefined, node.attrs.label);
			state.closeNode();
		}
	}
}));

/** Presentation only: no transactions, no source rewrites. */
export function irisLinkView(
	node: Node,
	links?: Pick<EditorLinks, 'label' | 'embed'>,
	open?: (href: string, element: HTMLElement) => void
) {
	const href = String(node.attrs.href);
	const stored = String(node.attrs.label) || href;
	const link = parseIrisHref(href)!;
	let stopped = false;
	const element = <K extends keyof HTMLElementTagNameMap>(tag: K, className = '', text = '') => {
		const created = document.createElement(tag);
		if (className) created.className = className;
		if (text) created.textContent = text;
		return created;
	};
	const button = (className: string, text: string) => {
		const created = element('button', className, text);
		created.type = 'button';
		created.onclick = (event) => {
			event.preventDefault();
			open?.(href, created);
		};
		return created;
	};
	let dom: HTMLElement;
	if (link.kind === 'row') {
		const mention = button('iris-mention', stored);
		mention.dataset.state = links ? 'loading' : 'stored';
		mention.title = `Open ${link.table} record`;
		links?.label(link.table, link.id).then(
			(result) => {
				if (stopped) return;
				mention.dataset.state = result.label === null ? 'unavailable' : result.trashed ? 'trashed' : 'live';
				mention.textContent =
					result.label === null
						? `${stored} (unavailable)`
						: result.trashed
							? `${result.label} (in trash)`
							: result.label;
			},
			() => {
				if (!stopped) mention.dataset.state = 'stored';
			}
		);
		dom = mention;
	} else {
		dom = element('span', 'iris-embed');
		dom.setAttribute('role', 'group');
		const title = element('span', 'iris-embed-title', stored);
		const header = element('span', 'iris-embed-header');
		header.replaceChildren(title, button('iris-embed-open', 'Open view'));
		const body = element('span', 'iris-embed-body', links ? 'Loading view…' : '');
		dom.replaceChildren(header, body);
		dom.setAttribute('aria-label', `Embedded view ${stored}`);
		links?.embed(link.table, link.id).then(
			(embed) => {
				if (stopped) return;
				if (embed.unavailable) {
					dom.dataset.state = 'unavailable';
					title.textContent = `${stored} (unavailable)`;
					body.textContent = embed.unavailable;
					return;
				}
				dom.dataset.state = 'live';
				title.textContent = embed.name ?? stored;
				dom.setAttribute('aria-label', `Embedded view ${title.textContent}`);
				const table = element('table');
				const head = table.createTHead().insertRow();
				for (const column of embed.columns) head.appendChild(element('th', '', column.label));
				const rows = table.createTBody();
				for (const row of embed.rows) {
					const tr = rows.insertRow();
					for (const column of embed.columns)
						tr.appendChild(element('td', '', cellText(row.record[column.column], column.type)));
				}
				body.replaceChildren(
					...(embed.rows.length ? [table] : [element('span', 'iris-embed-note', 'No rows match this view.')]),
					...(embed.more ? [element('span', 'iris-embed-note', 'More rows in the view')] : [])
				);
			},
			(error) => {
				if (!stopped) body.textContent = error instanceof Error ? error.message : 'The view could not load.';
			}
		);
	}
	dom.contentEditable = 'false';
	dom.dataset.irisLink = href;
	return {
		dom,
		stopEvent: () => true,
		ignoreMutation: () => true,
		destroy() {
			stopped = true;
		}
	};
}
