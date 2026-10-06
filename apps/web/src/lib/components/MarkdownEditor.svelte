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
	let controller = $state<MarkdownController>();
	let source = $state(false);
	let error = $state('');
	let blockMenu = $state(false);
	let linkOpen = $state(false);
	let linkURL = $state('');
	let linkError = $state('');
	let selectedLink = $state(''),
		openingLink = $state(false),
		openError = $state('');
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
	let disposed = false;
	async function openSelectedLink() {
		if (openingLink) return;
		openingLink = true;
		openError = '';
		try {
			if (fileKey) {
				if (onopenfile) await onopenfile(fileKey);
				else {
					if (!resolveFile) throw Error('Connect to your hub to download this file.');
					const file = await resolveFile(fileKey);
					if (disposed) {
						file.dispose();
						return;
					}
					downloads.push(file.dispose);
					const link = document.createElement('a');
					link.href = file.url;
					link.download = fileKey.split('/').at(-1) || 'attachment';
					document.body.appendChild(link);
					link.click();
					link.remove();
				}
			} else if (!onopenlink || !(await onopenlink(selectedLink))) {
				throw Error(
					'This link has no record available in this workspace. Use the original link below.'
				);
			}
			selectedLink = '';
		} catch (reason) {
			openError = reason instanceof Error ? reason.message : 'The link could not open.';
		} finally {
			openingLink = false;
		}
	}
	let menu = $state<HTMLDivElement>();
	let linkInput = $state<HTMLInputElement>();
	async function openBlocks() {
		blockMenu = true;
		await tick();
		menu?.querySelector<HTMLButtonElement>('button')?.focus();
	}
	async function openLink() {
		linkOpen = true;
		linkError = '';
		await tick();
		linkInput?.focus();
	}
	function applyLink() {
		if (controller?.command('link', linkURL.trim())) {
			linkOpen = false;
			linkURL = '';
		} else linkError = 'Select some text and enter an http, https, mailto or tel link.';
	}
	function menuKeys(event: KeyboardEvent) {
		const buttons = [...(menu?.querySelectorAll('button') ?? [])];
		const active = buttons.indexOf(document.activeElement as HTMLButtonElement);
		if (event.key === 'Escape') {
			event.preventDefault();
			blockMenu = false;
			controller?.focus();
		} else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
			event.preventDefault();
			buttons[
				(active + (event.key === 'ArrowDown' ? 1 : buttons.length - 1)) % buttons.length
			]?.focus();
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
		void import('../markdown-editor')
			.then(async ({ createMarkdownEditor }) => {
				if (disposed) return;
				return createMarkdownEditor(host, {
					value,
					label,
					id: `${id}-rich`,
					resolveFile: (key, signal) => {
						if (!resolveFile)
							return Promise.reject(Error('Connect to your hub to view this image.'));
						return resolveFile(key, signal);
					},
					onopenlink: (href) => {
						selectedLink = href;
						openError = '';
					},
					onslash: openBlocks,
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
			for (const dispose of downloads) dispose();
			void controller?.destroy();
		};
	});
	$effect(() => {
		controller?.replaceMarkdown(value);
		controller?.setReadOnly(disabled);
	});
</script>

<div class="markdown-editor">
	<div class="editor-bar">
		<div role="toolbar" aria-label={`${label} formatting`}>
			{#each tools as tool}
				<button
					type="button"
					aria-label={tool.name}
					title={tool.name}
					disabled={disabled || source || !controller}
					onmousedown={(event) => event.preventDefault()}
					onclick={() => controller?.command(tool.command)}><tool.icon size={18} /></button
				>
			{/each}
			<button
				type="button"
				aria-label="Link"
				title="Link"
				disabled={disabled || source || !controller}
				onmousedown={(event) => event.preventDefault()}
				onclick={openLink}><IconLink size={18} /></button
			>
		</div>
		<div class="modes">
			<button
				type="button"
				aria-label={`${label} write`}
				aria-pressed={!source}
				onclick={() => (source = false)}><IconPencil size={15} /> Write</button
			>
			<button
				type="button"
				aria-label={`${label} source`}
				aria-pressed={source}
				onclick={() => (source = true)}><IconCode size={15} /> Source</button
			>
		</div>
	</div>
	{#if linkOpen}
		<div class="link-bar">
			<input
				bind:this={linkInput}
				aria-label="Link URL"
				bind:value={linkURL}
				type="url"
				placeholder="https://"
				{disabled}
				onkeydown={(event) => {
					if (event.key === 'Enter') {
						event.preventDefault();
						applyLink();
					}
					if (event.key === 'Escape') {
						linkOpen = false;
						controller?.focus();
					}
				}}
			/>
			<button type="button" {disabled} onclick={applyLink}>Apply link</button>
			<button
				type="button"
				onclick={() => {
					linkOpen = false;
					controller?.focus();
				}}>Cancel</button
			>
		</div>
		{#if linkError}<p role="status">{linkError}</p>{/if}
	{/if}
	{#if blockMenu && !source}
		<div
			class="block-menu"
			role="menu"
			aria-label="Insert block"
			tabindex="-1"
			bind:this={menu}
			onkeydown={menuKeys}
		>
			{#each tools.filter((tool) => !['bold', 'italic', 'undo', 'redo'].includes(tool.command)) as tool}
				<button
					type="button"
					role="menuitem"
					{disabled}
					onclick={() => {
						controller?.command(tool.command);
						blockMenu = false;
					}}><tool.icon size={18} />{tool.name}</button
				>
			{/each}
		</div>
	{/if}
	<div bind:this={host} class="rich-document" hidden={source}></div>
	{#if selectedLink}
		<div class="link-destination" role="group" aria-label="Open document link">
			<p>{selectedLink}</p>
			{#if fileKey || onopenlink}<button
					type="button"
					disabled={openingLink}
					onclick={openSelectedLink}>{fileKey ? 'Download file' : 'Open in workspace'}</button
				>{/if}
			{#if externalLink}<a href={externalLink} target="_blank" rel="noopener noreferrer"
					>Open original link</a
				>{/if}
			<button type="button" disabled={openingLink} onclick={() => (selectedLink = '')}
				>Close link</button
			>
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
		border: 1px solid var(--color-rule);
		border-radius: 0.6rem;
		overflow: hidden;
		background: var(--color-paper);
	}
	.link-destination {
		padding: 0.75rem;
		border-top: 1px solid var(--color-rule);
		overflow-wrap: anywhere;
	}
	.link-destination a {
		color: var(--color-accent);
		text-decoration: underline;
		margin: 0 0.5rem;
	}
	.rich-document :global([data-type='retained-image'] img) {
		max-width: 100%;
		max-height: 70vh;
		object-fit: contain;
	}
	.editor-bar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 0.5rem;
		padding: 0.4rem;
		border-bottom: 1px solid var(--color-rule);
		background: var(--color-bone);
	}
	[role='toolbar'],
	.modes {
		display: flex;
		gap: 0.15rem;
	}
	[role='toolbar'] {
		flex-wrap: wrap;
	}
	.modes {
		flex-shrink: 0;
	}
	button {
		display: inline-flex;
		align-items: center;
		gap: 0.25rem;
		padding: 0.35rem;
		border-radius: 0.3rem;
		font-size: 0.75rem;
		color: var(--color-muted);
		cursor: pointer;
	}
	button:hover,
	button[aria-pressed='true'] {
		background: var(--color-paper);
		color: var(--color-ink);
	}
	button:disabled {
		opacity: 0.4;
		cursor: default;
	}
	button:focus-visible {
		outline: 2px solid var(--color-accent);
		outline-offset: 1px;
	}
	.link-bar {
		display: flex;
		flex-wrap: wrap;
		gap: 0.4rem;
		padding: 0.5rem;
	}
	.link-bar input {
		flex: 1;
		min-width: 7rem;
		border: 1px solid var(--color-rule);
		border-radius: 0.3rem;
		padding: 0.35rem;
	}
	.block-menu {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 0.25rem;
		padding: 0.5rem;
		border-bottom: 1px solid var(--color-rule);
		background: var(--color-bone);
	}
	textarea {
		display: block;
		width: 100%;
		min-height: 16rem;
		resize: vertical;
		padding: 1rem;
		border: 0;
		background: transparent;
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 0.82rem;
		line-height: 1.7;
	}
	@media (max-width: 640px) {
		textarea {
			font-size: max(1rem, 16px);
		}
	}
	.rich-document :global(.ProseMirror) {
		min-height: 16rem;
		padding: 1rem;
		outline: none;
		font-size: 0.92rem;
		line-height: 1.75;
		overflow-wrap: anywhere;
	}
	.rich-document :global(.ProseMirror:focus-visible) {
		box-shadow: inset 0 0 0 2px var(--color-accent);
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
