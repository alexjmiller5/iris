<script lang="ts">
	import { onMount, tick } from 'svelte';
	import {
		IconItalic,
		IconLink,
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
		IconArrowForwardUp
	} from '@tabler/icons-svelte';
	import type { MarkdownCommand, MarkdownController } from '../markdown-editor';
	let {
		value = $bindable(''),
		label,
		id,
		disabled = false,
		onchange,
		onready
	}: {
		value?: string;
		label: string;
		id: string;
		disabled?: boolean;
		onchange?(value: string): void;
		onready?(): void;
	} = $props();
	let host: HTMLDivElement;
	let editorRoot: HTMLDivElement;
	let controller = $state<MarkdownController>();
	let source = $state(false);
	let error = $state('');
	let popup = $state<'options' | 'blocks' | 'link' | 'help' | null>(null);
	let selected = $state(false);
	let selectionRange: Range | undefined;
	let optionsButton: HTMLButtonElement;
	let linkURL = $state('');
	let linkError = $state('');
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
		await tick();
		menu?.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus();
	}
	function closePopup(restoreFocus = true) {
		const previous = popup;
		popup = null;
		if (restoreFocus) {
			if (previous === 'options' || previous === 'help') optionsButton.focus();
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
	onMount(() => {
		let disposed = false;
		void import('../markdown-editor')
			.then(async ({ createMarkdownEditor }) => {
				if (disposed) return;
				return createMarkdownEditor(host, {
					value,
					label,
					id: `${id}-rich`,
					onslash: () => openMenu('blocks'),
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
			{#each tools.filter((tool) => !['bold', 'italic', 'undo', 'redo'].includes(tool.command)) as tool}
				<button
					type="button"
					role="menuitem"
					onclick={() => {
						controller?.command(tool.command);
						popup = null;
					}}><tool.icon size={18} />{tool.name}</button
				>
			{/each}
		</div>
	{/if}
	<div bind:this={host} class="rich-document" hidden={source}></div>
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
	.block-menu {
		display: grid;
		width: 12rem;
	}
	.options-menu button,
	.block-menu button {
		width: 100%;
		text-align: left;
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
		.editor-popup button {
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
