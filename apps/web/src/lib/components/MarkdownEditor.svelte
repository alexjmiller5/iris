<script lang="ts">
	import { getContext, onMount, tick } from 'svelte';
	import {
		IconItalic,
		IconLink,
		IconLetterT,
		IconH1,
		IconH2,
		IconH3,
		IconCode,
		IconPencil,
		IconDots,
		IconHelp,
		IconBold,
		IconList,
		IconListNumbers,
		IconCheckbox,
		IconQuote,
		IconTable,
		IconArrowBackUp,
		IconArrowForwardUp,
		IconAt,
		IconLayoutList
	} from '@tabler/icons-svelte';
	import { irisHref } from 'iris-core/client';
	import {
		EDITOR_LINKS,
		slashMatches,
		type EditorLinks,
		type LinkTarget,
		type MentionTable,
		type SlashMatch
	} from '../editor-links';
	import type { MarkdownCommand, MarkdownController } from '../markdown-editor';
	import { retainedFileKey, type RetainedFileResolver } from '../retained-files';
	let {
		value = $bindable(''),
		label,
		id,
		disabled = false,
		onchange,
		onready,
		resolveFile,
		onopenlink,
		onopenfile
	}: {
		value?: string;
		label: string;
		id: string;
		disabled?: boolean;
		onchange?(value: string): void;
		onready?(): void;
		resolveFile?: RetainedFileResolver;
		onopenlink?(href: string): Promise<boolean>;
		onopenfile?(key: string): Promise<void>;
	} = $props();
	let host: HTMLDivElement;
	let editorRoot: HTMLDivElement;
	let controller = $state<MarkdownController>();
	let source = $state(false);
	let error = $state('');
	let popup = $state<'options' | 'blocks' | 'link' | 'help' | 'destination' | 'picker' | null>(
		null
	);
	const links = getContext<EditorLinks | undefined>(EDITOR_LINKS);
	let slashQuery = $state('');
	let mentionTables = $state<MentionTable[]>([]);
	let picker = $state<{ kind: 'row' | 'view'; table?: string; title: string; noun: string }>();
	let pickerQuery = $state('');
	let pickerResults = $state<LinkTarget[]>([]);
	let pickerStatus = $state('');
	let pickerViews: LinkTarget[] | undefined;
	let pickerSearch = 0;
	const words = (text: string) => text.replace(/_/g, ' ');
	const capitalized = (text: string) => words(text).replace(/^./, (c) => c.toUpperCase());
	async function choose(match: SlashMatch) {
		picker =
			match.kind === 'view'
				? { kind: 'view', title: 'Embed a saved view', noun: 'views' }
				: match.kind === 'mention'
					? { kind: 'row', title: 'Mention a record', noun: 'records' }
					: {
							kind: 'row',
							table: match.table.id,
							title: `Mention a ${words(match.table.command)}`,
							noun: words(match.table.id)
						};
		pickerQuery = '';
		pickerResults = [];
		pickerViews = undefined;
		pickerStatus = picker.kind === 'view' ? 'Loading views…' : `Type to search ${picker.noun}.`;
		popup = 'picker';
		await tick();
		menu?.querySelector<HTMLInputElement>('input')?.focus();
		if (picker.kind === 'view') void searchPicker();
	}
	async function searchPicker() {
		if (!links || !picker) return;
		const request = ++pickerSearch,
			query = pickerQuery.trim().toLowerCase(),
			current = picker;
		try {
			let results: LinkTarget[];
			if (current.kind === 'view') {
				pickerViews ??= (await links.views()).map(({ table, id, name }) => ({
					table,
					id,
					label: name
				}));
				results = pickerViews.filter(
					(view) => !query || `${view.label} ${words(view.table)}`.toLowerCase().includes(query)
				);
			} else results = await links.search(current.table, pickerQuery);
			if (request !== pickerSearch || popup !== 'picker') return;
			pickerResults = results.slice(0, 20);
			pickerStatus = results.length
				? ''
				: current.kind === 'row' && !query
					? `Type to search ${current.noun}.`
					: `No matching ${current.noun}.`;
		} catch (reason) {
			if (request === pickerSearch)
				pickerStatus = reason instanceof Error ? reason.message : 'Search failed.';
		}
	}
	function insertPicked(target: LinkTarget) {
		if (!picker) return;
		const inserted = controller?.insertLink(
			irisHref(picker.kind, target.table, target.id),
			target.label
		);
		if (inserted) popup = null;
	}
	async function openIrisLink(href: string, element: HTMLElement) {
		if (!onopenlink || openingLink) return;
		openingLink = true;
		openError = '';
		try {
			if (!(await onopenlink(href)))
				throw Error('This record or view is not available in this workspace.');
		} catch (reason) {
			if (disposed || (reason instanceof Error && reason.name === 'AbortError')) return;
			selectedLink = href;
			linkAnchor = element;
			popup = 'destination';
			openError = reason instanceof Error ? reason.message : 'The link could not open.';
		} finally {
			openingLink = false;
		}
	}
	let selected = $state(false);
	let selectionRange: Range | undefined;
	let optionsButton: HTMLButtonElement;
	let linkURL = $state('');
	let linkError = $state('');
	let selectedLink = $state(''),
		openingLink = $state(false),
		openError = $state('');
	let linkAnchor: HTMLElement | undefined;
	const fileKey = $derived(retainedFileKey(selectedLink));
	const externalLink = $derived.by(() => {
		try {
			if (/[\s\\\u0000-\u001f\u007f]/.test(selectedLink)) return null;
			const url = new URL(selectedLink);
			return ['https:', 'http:'].includes(url.protocol) && !url.username && !url.password
				? url.href
				: null;
		} catch {
			return null;
		}
	});
	const downloads: (() => void)[] = [];
	const downloadAbort = new AbortController();
	let disposed = false;
	async function openSelectedLink() {
		if (openingLink) return;
		const href = selectedLink;
		const key = fileKey;
		openingLink = true;
		openError = '';
		try {
			if (key) {
				if (onopenfile) await onopenfile(key);
				else {
					if (!resolveFile) throw Error('Connect to your hub to download this file.');
					const file = await resolveFile(key, downloadAbort.signal);
					if (disposed) {
						file.dispose();
						return;
					}
					downloads.push(file.dispose);
					const link = document.createElement('a');
					link.href = file.url;
					link.download = key.split('/').at(-1) || 'attachment';
					document.body.appendChild(link);
					link.click();
					link.remove();
				}
			} else if (!onopenlink || !(await onopenlink(href))) {
				throw Error(
					'This link has no record available in this workspace. Use the original link below.'
				);
			}
			if (!disposed && selectedLink === href && popup === 'destination') closePopup(false);
		} catch (reason) {
			if (reason instanceof Error && reason.name === 'AbortError') return;
			if (!disposed && selectedLink === href && popup === 'destination')
				openError = reason instanceof Error ? reason.message : 'The link could not open.';
		} finally {
			openingLink = false;
		}
	}
	let menu = $state<HTMLDivElement>();
	let linkInput = $state<HTMLInputElement>();
	function trackSelection() {
		const selection = document.getSelection();
		selected = Boolean(
			selection &&
			!selection.isCollapsed &&
			selection.toString().length &&
			host?.contains(selection.anchorNode) &&
			host.contains(selection.focusNode)
		);
		if (selection?.rangeCount && host?.contains(selection.anchorNode))
			selectionRange = selection.getRangeAt(0).cloneRange();
	}
	function caretRect() {
		const rect = selectionRange?.getBoundingClientRect();
		if (rect?.height) return rect;
		// Empty paragraphs have no range rectangle, but their line box is still the caret anchor.
		const node = selectionRange?.startContainer;
		const line = node instanceof Element ? node : node?.parentElement;
		return (line ?? host).getBoundingClientRect();
	}
	function placePopup(
		node: HTMLElement,
		{ anchor, above = false }: { anchor(): DOMRect; above?: boolean }
	) {
		// The top layer escapes containment and clipping in virtualized table rows.
		node.popover = 'manual';
		node.showPopover();
		const place = () => {
			const rect = anchor();
			const viewport = window.visualViewport;
			const left = viewport?.offsetLeft ?? 0;
			const top = viewport?.offsetTop ?? 0;
			const width = viewport?.width ?? window.innerWidth;
			const height = viewport?.height ?? window.innerHeight;
			node.style.maxWidth = `${Math.max(0, width - 16)}px`;
			node.style.maxHeight = `${Math.max(0, height - 16)}px`;
			const size = node.getBoundingClientRect();
			const aboveTop = rect.top - size.height - 6;
			const belowTop = rect.bottom + 6;
			const preferred =
				(above || belowTop + size.height > top + height - 8) && aboveTop >= top + 8
					? aboveTop
					: belowTop;
			node.style.left = `${Math.max(left + 8, Math.min(rect.left, left + width - size.width - 8))}px`;
			node.style.top = `${Math.max(top + 8, Math.min(preferred, top + height - size.height - 8))}px`;
		};
		place();
		const observer = new ResizeObserver(place);
		observer.observe(node);
		document.addEventListener('selectionchange', place);
		document.addEventListener('scroll', place, true);
		window.addEventListener('resize', place);
		window.visualViewport?.addEventListener('resize', place);
		window.visualViewport?.addEventListener('scroll', place);
		return {
			destroy() {
				observer.disconnect();
				document.removeEventListener('selectionchange', place);
				document.removeEventListener('scroll', place, true);
				window.removeEventListener('resize', place);
				window.visualViewport?.removeEventListener('resize', place);
				window.visualViewport?.removeEventListener('scroll', place);
			}
		};
	}
	async function openMenu(next: 'blocks' | 'options') {
		trackSelection();
		popup = popup === next ? null : next;
		slashQuery = '';
		await tick();
		menu?.querySelector<HTMLElement>('input, button:not(:disabled)')?.focus();
		if (popup === 'blocks' && links)
			links.tables().then(
				(tables) => (mentionTables = tables),
				() => (mentionTables = [])
			);
	}
	function closePopup(restoreFocus = true) {
		const previous = popup;
		popup = null;
		selectedLink = '';
		if (restoreFocus) {
			if (previous === 'destination') linkAnchor?.focus({ preventScroll: true });
			else if (previous === 'options' || previous === 'help') optionsButton.focus();
			else controller?.focus();
		}
	}
	async function setMode(next: boolean) {
		popup = null;
		selected = false;
		source = next;
		await tick();
		if (source) document.getElementById(id)?.focus();
		else controller?.focus();
	}
	async function openLink() {
		popup = 'link';
		linkError = '';
		await tick();
		linkInput?.focus();
	}
	function applyLink() {
		if (controller?.command('link', linkURL.trim())) {
			popup = null;
			linkURL = '';
		} else linkError = 'Select some text and enter an http, https, mailto or tel link.';
	}
	function menuKeys(event: KeyboardEvent) {
		const buttons = [...(menu?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)') ?? [])];
		const active = buttons.indexOf(document.activeElement as HTMLButtonElement);
		if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
			event.preventDefault();
			buttons[
				(active + (event.key === 'ArrowDown' ? 1 : buttons.length - 1)) % buttons.length
			]?.focus();
		} else if (event.key === 'Home' || event.key === 'End') {
			event.preventDefault();
			buttons[event.key === 'Home' ? 0 : buttons.length - 1]?.focus();
		}
	}
	const tools: { command: MarkdownCommand; name: string; icon: typeof IconH1 }[] = [
		{ command: 'bold', name: 'Bold', icon: IconBold },
		{ command: 'italic', name: 'Italic', icon: IconItalic },
		{ command: 'paragraph', name: 'Text', icon: IconLetterT },
		{ command: 'heading1', name: 'Heading 1', icon: IconH1 },
		{ command: 'heading2', name: 'Heading 2', icon: IconH2 },
		{ command: 'heading3', name: 'Heading 3', icon: IconH3 },
		{ command: 'bullet', name: 'Bullet list', icon: IconList },
		{ command: 'ordered', name: 'Numbered list', icon: IconListNumbers },
		{ command: 'task', name: 'Task list', icon: IconCheckbox },
		{ command: 'quote', name: 'Quote', icon: IconQuote },
		{ command: 'codeBlock', name: 'Code block', icon: IconCode },
		{ command: 'table', name: 'Table', icon: IconTable },
		{ command: 'undo', name: 'Undo', icon: IconArrowBackUp },
		{ command: 'redo', name: 'Redo', icon: IconArrowForwardUp }
	];
	const slashTools = $derived(
		tools.filter(
			(tool) =>
				!['bold', 'italic', 'undo', 'redo'].includes(tool.command) &&
				tool.name
					.toLowerCase()
					.split(' ')
					.some((word) => word.startsWith(slashQuery.trim().toLowerCase()))
		)
	);
	const slashLinks = $derived(links ? slashMatches(slashQuery, mentionTables) : []);
	onMount(() => {
		void import('../markdown-editor')
			.then(async ({ createMarkdownEditor }) => {
				if (disposed) return;
				return createMarkdownEditor(host, {
					value,
					label,
					id: `${id}-rich`,
					onslash: () => openMenu('blocks'),
					links,
					onopenrecord: (href, element) => void openIrisLink(href, element),
					resolveFile: (key, signal, preview) => {
						if (!resolveFile)
							return Promise.reject(Error('Connect to your hub to view this image.'));
						return resolveFile(key, signal, preview);
					},
					onopenlink: async (href, anchor) => {
						selectedLink = href;
						linkAnchor = anchor;
						openError = '';
						popup = 'destination';
						await tick();
						menu
							?.querySelector<HTMLButtonElement>('button:not(:disabled)')
							?.focus({ preventScroll: true });
					},
					onchange(next) {
						if (!disposed) {
							value = next;
							onchange?.(next);
						}
					}
				});
			})
			.then((editor) => {
				if (!editor) return;
				if (disposed) {
					void editor.destroy();
					return;
				}
				controller = editor;
				onready?.();
			})
			.catch((reason) => {
				if (!disposed) {
					error = String(reason);
					source = true;
					onready?.();
				}
			});
		return () => {
			disposed = true;
			downloadAbort.abort();
			for (const dispose of downloads) dispose();
			void controller?.destroy();
		};
	});
	$effect(() => {
		controller?.replaceMarkdown(value);
		controller?.setReadOnly(disabled);
	});
</script>

<svelte:document
	onselectionchange={trackSelection}
	onpointerdown={(event) => {
		const target = event.target as Element;
		if (!editorRoot.contains(target) || !target.closest('.editor-popup, .options-trigger'))
			closePopup(false);
	}}
/>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions (handles keys bubbling from the editor and popup controls) -->
<div
	class="markdown-editor"
	bind:this={editorRoot}
	role="group"
	aria-label={`${label} editor`}
	onkeydown={(event) => {
		if (!popup) return;
		if (event.key === 'Escape') {
			event.preventDefault();
			event.stopPropagation();
			closePopup();
		} else if (event.key === 'Tab') {
			// Keep native focus traversal inside popups from committing an enclosing grid cell.
			event.stopPropagation();
		}
	}}
>
	<button
		class="options-trigger"
		bind:this={optionsButton}
		type="button"
		aria-label={`${label} options`}
		title="Editor options"
		aria-haspopup="menu"
		aria-expanded={popup === 'options'}
		onclick={() => openMenu('options')}><IconDots size={18} /></button
	>
	{#if popup === 'options'}
		<div
			class="editor-popup options-menu"
			role="menu"
			aria-label={`${label} options`}
			bind:this={menu}
			tabindex="-1"
			onkeydown={menuKeys}
			use:placePopup={{ anchor: () => optionsButton.getBoundingClientRect() }}
		>
			<button
				type="button"
				role="menuitem"
				aria-label={`${label} ${source ? 'write' : 'source'}`}
				disabled={source && !controller}
				onclick={() => setMode(!source)}
			>
				{#if source}<IconPencil size={17} />Write{:else}<IconCode size={17} />Source{/if}
			</button>
			{#each tools.filter((tool) => ['undo', 'redo'].includes(tool.command)) as tool}
				<button
					type="button"
					role="menuitem"
					aria-label={tool.name}
					disabled={disabled || source || !controller}
					onclick={() => {
						popup = null;
						controller?.command(tool.command);
					}}
				>
					<tool.icon size={17} />{tool.name}
				</button>
			{/each}
			<button
				type="button"
				role="menuitem"
				onclick={async () => {
					popup = 'help';
					await tick();
					menu?.querySelector<HTMLButtonElement>('button')?.focus();
				}}><IconHelp size={17} />Formatting help</button
			>
		</div>
	{/if}
	{#if selected && !source && !disabled && !popup}
		<div
			class="editor-popup selection-tools"
			role="toolbar"
			aria-label={`${label} formatting`}
			use:placePopup={{ anchor: caretRect, above: true }}
		>
			{#each tools.filter((tool) => ['bold', 'italic'].includes(tool.command)) as tool}
				<button
					type="button"
					aria-label={tool.name}
					title={tool.name}
					onmousedown={(event) => event.preventDefault()}
					onclick={() => controller?.command(tool.command)}><tool.icon size={18} /></button
				>
			{/each}
			<button
				type="button"
				aria-label="Link"
				title="Link"
				onmousedown={(event) => event.preventDefault()}
				onclick={openLink}><IconLink size={18} /></button
			>
			<button
				type="button"
				aria-label="Code"
				title="Code"
				onmousedown={(event) => event.preventDefault()}
				onclick={() => controller?.command('inlineCode')}><IconCode size={18} /></button
			>
		</div>
	{/if}
	{#if popup === 'help'}
		<div
			class="editor-popup formatting-help"
			role="dialog"
			aria-label="Formatting help"
			tabindex="-1"
			bind:this={menu}
			use:placePopup={{ anchor: () => optionsButton.getBoundingClientRect() }}
		>
			<strong>Format as you type</strong>
			<p>At the start of a line, type a prefix followed by a space.</p>
			<dl>
				<dt>#</dt>
				<dd>Heading</dd>
				<dt>##</dt>
				<dd>Smaller heading</dd>
				<dt>-</dt>
				<dd>Bullet list</dd>
				<dt>1.</dt>
				<dd>Numbered list</dd>
				<dt>&gt;</dt>
				<dd>Quote</dd>
			</dl>
			<p>Type / on an empty line for more blocks. Select text for bold, italic and links.</p>
			<button type="button" onclick={() => closePopup()}>Close formatting help</button>
		</div>
	{/if}
	{#if popup === 'link' && !source && !disabled}
		<div
			class="editor-popup link-bar"
			role="dialog"
			aria-label="Add link"
			tabindex="-1"
			use:placePopup={{ anchor: caretRect }}
		>
			<input
				bind:this={linkInput}
				aria-label="Link URL"
				bind:value={linkURL}
				type="url"
				placeholder="https://"
				onkeydown={(event) => {
					if (event.key === 'Enter') {
						event.preventDefault();
						applyLink();
					}
				}}
			/>
			<div>
				<button type="button" onclick={applyLink}>Apply link</button>
				<button type="button" onclick={() => closePopup()}>Cancel</button>
			</div>
			{#if linkError}<p role="status">{linkError}</p>{/if}
		</div>
	{/if}
	{#if popup === 'blocks' && !source && !disabled}
		<div
			class="editor-popup block-menu"
			role="menu"
			aria-label="Insert block"
			tabindex="-1"
			bind:this={menu}
			onkeydown={menuKeys}
			use:placePopup={{ anchor: caretRect }}
		>
			<input
				class="slash-query"
				aria-label="Filter blocks"
				placeholder="Filter"
				bind:value={slashQuery}
				onkeydown={(event) => {
					if (event.key === 'Enter') {
						event.preventDefault();
						menu?.querySelector<HTMLButtonElement>('button')?.click();
					}
				}}
			/>
			{#each slashTools as tool}
				<button
					type="button"
					role="menuitem"
					onclick={() => {
						controller?.command(tool.command);
						popup = null;
					}}><tool.icon size={18} />{tool.name}</button
				>
			{/each}
			{#each slashLinks as match}
				<button type="button" role="menuitem" onclick={() => choose(match)}>
					{#if match.kind === 'view'}<IconLayoutList size={18} />Embed view
					{:else if match.kind === 'mention'}<IconAt size={18} />Mention
					{:else}<IconAt size={18} />{capitalized(match.table.command)}<span class="hint"
							>{words(match.table.id)}</span
						>{/if}
				</button>
			{/each}
			{#if !slashTools.length && !slashLinks.length}<p class="empty">No matching blocks.</p>{/if}
		</div>
	{/if}
	{#if popup === 'picker' && picker && !source && !disabled}
		<div
			class="editor-popup link-picker"
			role="dialog"
			aria-label={picker.title}
			tabindex="-1"
			bind:this={menu}
			onkeydown={menuKeys}
			use:placePopup={{ anchor: caretRect }}
		>
			<input
				aria-label={picker.title}
				placeholder={`Search ${picker.noun}`}
				bind:value={pickerQuery}
				oninput={() => void searchPicker()}
				onkeydown={(event) => {
					if (event.key === 'Enter') {
						event.preventDefault();
						if (pickerResults[0]) insertPicked(pickerResults[0]);
					}
				}}
			/>
			{#each pickerResults as target (`${target.table}/${target.id}`)}
				<button type="button" role="menuitem" onclick={() => insertPicked(target)}
					><span class="pick-label">{target.label}</span><span class="hint"
						>{words(target.table)}</span
					></button
				>
			{/each}
			{#if pickerStatus}<p class="empty" role="status">{pickerStatus}</p>{/if}
		</div>
	{/if}
	<div bind:this={host} class="rich-document" hidden={source}></div>
	{#if popup === 'destination'}
		<div
			class="editor-popup link-destination"
			role="dialog"
			aria-label="Open document link"
			tabindex="-1"
			bind:this={menu}
			use:placePopup={{ anchor: () => linkAnchor?.getBoundingClientRect() ?? caretRect() }}
		>
			<p>{selectedLink}</p>
			{#if fileKey || onopenlink}<button
					type="button"
					disabled={openingLink}
					onclick={openSelectedLink}>{fileKey ? 'Download file' : 'Open in workspace'}</button
				>{/if}
			{#if externalLink}<a href={externalLink} target="_blank" rel="noopener noreferrer"
					>Open original link</a
				>{/if}
			<button type="button" onclick={() => closePopup()}>Close link</button>
			{#if openError}<p role="status">{openError}</p>{/if}
		</div>
	{/if}
	{#if source}<textarea
			{id}
			aria-label={label}
			bind:value
			{disabled}
			oninput={(event) => {
				value = event.currentTarget.value;
				onchange?.(value);
			}}
			rows="12"
			spellcheck="false"></textarea>{/if}
	{#if error}<p role="status">
			The visual editor could not open. Your Markdown is available in Source.
		</p>{/if}
</div>

<style>
	.markdown-editor {
		position: relative;
		border: 1px solid var(--color-rule);
		border-radius: 0.6rem;
		background: var(--color-paper);
	}
	.link-destination {
		width: 19rem;
		padding: 0.5rem;
		overflow-wrap: anywhere;
	}
	.link-destination p {
		margin: 0.25rem 0 0.5rem;
		font-size: 0.8rem;
	}
	.link-destination a {
		color: var(--color-accent);
		text-decoration: underline;
		display: inline-flex;
		align-items: center;
		padding: 0.45rem;
		font-size: 0.8rem;
	}
	.rich-document :global([data-type='retained-image'] img) {
		max-width: 100%;
		max-height: 70vh;
		object-fit: contain;
	}
	.options-trigger {
		justify-content: center;
		position: absolute;
		top: 0.35rem;
		right: 0.35rem;
		z-index: 1;
	}
	button {
		display: inline-flex;
		align-items: center;
		gap: 0.5rem;
		padding: 0.45rem;
		min-height: 2rem;
		border-radius: 0.3rem;
		font-size: 0.8rem;
		color: var(--color-muted);
		cursor: pointer;
	}
	button:hover,
	button:focus-visible {
		background: var(--color-bone);
		color: var(--color-ink);
	}
	button:disabled {
		opacity: 0.4;
		cursor: default;
	}
	button:focus-visible {
		outline: 2px solid var(--color-accent);
		outline-offset: -2px;
	}
	.editor-popup {
		position: fixed;
		inset: auto;
		margin: 0;
		color: var(--color-ink);
		z-index: 50;
		padding: 0.3rem;
		border: 1px solid var(--color-rule);
		border-radius: 0.5rem;
		background: var(--color-paper);
		box-shadow: 0 4px 16px #0002;
		overflow: auto;
	}
	.selection-tools {
		display: flex;
		gap: 0.1rem;
	}
	.options-menu,
	.block-menu,
	.link-picker {
		display: grid;
		width: 12rem;
	}
	.block-menu {
		width: 14rem;
	}
	.link-picker {
		width: 18rem;
	}
	.options-menu button,
	.block-menu button,
	.link-picker button {
		width: 100%;
		text-align: left;
	}
	.slash-query,
	.link-picker input {
		width: 100%;
		min-width: 0;
		margin-bottom: 0.25rem;
		border: 1px solid var(--color-rule);
		border-radius: 0.3rem;
		padding: 0.35rem 0.45rem;
		font-size: 0.85rem;
		background: var(--color-paper);
		color: var(--color-ink);
	}
	.hint {
		margin-left: auto;
		font-size: 0.72rem;
		color: var(--color-muted);
	}
	.pick-label {
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		color: var(--color-ink);
	}
	.empty {
		margin: 0.35rem 0.45rem;
		font-size: 0.78rem;
		color: var(--color-muted);
	}
	.rich-document :global(.iris-mention) {
		display: inline;
		min-height: 0;
		padding: 0 0.3rem;
		border-radius: 0.3rem;
		background: var(--color-bone);
		color: var(--color-accent);
		font-size: inherit;
		font-weight: 550;
		line-height: inherit;
		white-space: normal;
	}
	.rich-document :global(.iris-mention[data-state='unavailable']),
	.rich-document :global(.iris-mention[data-state='trashed']) {
		background: transparent;
		color: var(--color-muted);
		outline: 1px dashed var(--color-rule);
		outline-offset: -1px;
		font-weight: 400;
	}
	.rich-document :global(.iris-embed) {
		display: block;
		margin: 0.4rem 0;
		border: 1px solid var(--color-rule);
		border-radius: 0.5rem;
		overflow: hidden;
		white-space: normal;
		line-height: 1.4;
	}
	.rich-document :global(.iris-embed-header) {
		display: flex;
		align-items: center;
		gap: 0.75rem;
		padding: 0.35rem 0.35rem 0.35rem 0.75rem;
		border-bottom: 1px solid var(--color-rule);
		background: var(--color-bone);
	}
	.rich-document :global(.iris-embed-title) {
		flex: 1;
		min-width: 0;
		font-size: 0.85rem;
		font-weight: 650;
		overflow-wrap: anywhere;
	}
	.rich-document :global(.iris-embed-open) {
		font-size: 0.78rem;
		color: var(--color-accent);
	}
	.rich-document :global(.iris-embed-body) {
		display: block;
		overflow-x: auto;
		font-size: 0.8rem;
	}
	.rich-document :global(.iris-embed table) {
		margin: 0;
	}
	.rich-document :global(.iris-embed th),
	.rich-document :global(.iris-embed td) {
		border: 0;
		border-bottom: 1px solid var(--color-rule);
		padding: 0.35rem 0.75rem;
		text-align: left;
		vertical-align: top;
	}
	.rich-document :global(.iris-embed th) {
		font-weight: 550;
		color: var(--color-muted);
	}
	.rich-document :global(.iris-embed tr:last-child td) {
		border-bottom: 0;
	}
	.rich-document :global(.iris-embed-note),
	.rich-document :global(.iris-embed-body:not(:has(*))) {
		display: block;
		padding: 0.45rem 0.75rem;
		color: var(--color-muted);
	}
	.link-bar {
		width: 19rem;
		padding: 0.5rem;
	}
	.link-bar input {
		width: 100%;
		min-width: 0;
		border: 1px solid var(--color-rule);
		border-radius: 0.3rem;
		padding: 0.4rem;
		font-size: 1rem;
	}
	.formatting-help {
		width: 17rem;
		padding: 0.8rem;
		font-size: 0.8rem;
	}
	.formatting-help p {
		margin: 0.5rem 0;
		color: var(--color-muted);
	}
	.formatting-help dl {
		display: grid;
		grid-template-columns: 2.5rem 1fr;
		gap: 0.3rem;
	}
	.formatting-help dt {
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
	}
	.formatting-help dd {
		margin: 0;
	}

	textarea {
		display: block;
		width: 100%;
		min-height: 16rem;
		resize: vertical;
		padding: 1rem 2.75rem 1rem 1rem;
		border: 0;
		background: transparent;
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 0.82rem;
		line-height: 1.7;
	}
	.rich-document :global(.ProseMirror) {
		min-height: 16rem;
		padding: 1rem 2.75rem 1rem 1rem;
		outline: none;
		font-size: 0.92rem;
		line-height: 1.75;
		white-space: pre-wrap;
		overflow-wrap: anywhere;
	}
	@media (max-width: 640px) {
		textarea,
		.rich-document :global(.ProseMirror) {
			font-size: 1rem;
		}
	}
	@media (max-width: 640px), (pointer: coarse) {
		.options-trigger,
		.editor-popup button,
		.link-destination a {
			min-width: 2.75rem;
			min-height: 2.75rem;
		}
		textarea,
		.rich-document :global(.ProseMirror) {
			padding-right: 3.25rem;
		}
	}
	.rich-document :global(.ProseMirror:focus-visible) {
		box-shadow: inset 0 0 0 2px var(--color-accent);
	}
	.rich-document :global(.ProseMirror > :first-child) {
		margin-top: 0;
	}
	.rich-document :global(.ProseMirror > :last-child) {
		margin-bottom: 0;
	}
	.rich-document :global(h1) {
		font-size: 1.8rem;
		font-weight: 650;
		line-height: 1.3;
		margin: 0.6em 0;
	}
	.rich-document :global(h2) {
		font-size: 1.4rem;
		font-weight: 650;
		margin: 0.7em 0;
	}
	.rich-document :global(h3) {
		font-size: 1.15rem;
		font-weight: 650;
		margin: 0.7em 0;
	}
	.rich-document :global(p) {
		margin: 0.6em 0;
	}
	.rich-document :global(ul) {
		list-style: disc;
		padding-left: 1.5rem;
	}
	.rich-document :global(ol) {
		list-style: decimal;
		padding-left: 1.5rem;
	}
	.rich-document :global(blockquote) {
		border-left: 3px solid var(--color-rule);
		padding-left: 1rem;
		color: var(--color-muted);
	}
	.rich-document :global(pre) {
		padding: 0.75rem;
		border-radius: 0.4rem;
		background: var(--color-bone);
		overflow: auto;
	}
	.rich-document :global(code) {
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 0.85em;
	}
	.rich-document :global(table) {
		border-collapse: collapse;
		width: 100%;
	}
	.rich-document :global(td),
	.rich-document :global(th) {
		border: 1px solid var(--color-rule);
		padding: 0.4rem;
		min-width: 2rem;
	}
	.rich-document :global(a) {
		color: var(--color-accent);
		text-decoration: underline;
	}
	.rich-document :global([data-type='image-reference']) {
		display: inline-block;
		border: 1px dashed var(--color-rule);
		padding: 0.25rem 0.5rem;
		color: var(--color-muted);
	}
	.rich-document :global(li[data-item-type='task']) {
		display: flex;
		align-items: baseline;
		gap: 0.5rem;
		list-style: none;
	}
	.rich-document :global(li > div) {
		flex: 1;
		min-width: 0;
	}
	.rich-document :global(input[type='checkbox']) {
		accent-color: var(--color-accent);
	}
	p[role='status'] {
		padding: 0.5rem 1rem;
		font-size: 0.8rem;
	}
</style>
