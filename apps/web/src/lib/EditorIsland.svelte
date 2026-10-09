<script lang="ts">
	import MarkdownEditor from './components/MarkdownEditor.svelte';
	import { parseEditorDocument, type EditorDocument, type EditorMessage } from './editor-island';
	import { editorFiles } from './editor-files';
	import { onDestroy, setContext } from 'svelte';
	import { createEditorLinks, EDITOR_LINKS, type LinkRequest } from './editor-links';
	let { onMessage }: { onMessage(message: EditorMessage): void } = $props();
	let current = $state<EditorDocument>({ id: 'initial', value: '', label: 'Body', readOnly: true });
	let announced = false;
	const files = editorFiles((message) => onMessage(message));
	onDestroy(() => files.dispose());
	setContext(
		EDITOR_LINKS,
		createEditorLinks(((op, args) => files.core(current.id, op, args)) as LinkRequest)
	);
	export function receiveFile(input: unknown) {
		files.receive(input);
	}
	export function setDocument(input: unknown) {
		const next = parseEditorDocument(input);
		if (next.id !== current.id) files.dispose();
		current = next;
	}
	export function getDocument(): EditorDocument {
		return { ...current };
	}
	function ready() {
		if (!announced) {
			announced = true;
			onMessage({ type: 'ready' });
		}
	}
</script>

<div class="native-editor">
	{#each [current] as document (document.id)}
		<MarkdownEditor
			id="document"
			label={document.label}
			value={document.value}
			disabled={document.readOnly}
			resolveFile={files.resolve(document.id)}
			onopenfile={(key) => files.openFile(document.id, key)}
			onopenlink={(href) => files.openLink(document.id, href)}
			onready={ready}
			onchange={(value) => {
				if (document.id === current.id && !current.readOnly) {
					current.value = value;
					onMessage({ type: 'change', id: document.id, value });
				}
			}}
		/>
	{/each}
</div>

<style>
	:global(body:has(.native-editor)) {
		background: var(--color-paper);
	}
	/* On iPhone the document text follows the reader's Dynamic Type body size, which
	   WebKit tracks live; spacing keeps its rem scale, and headings stay a step above
	   the body so words still fit at accessibility sizes. The Mac keeps the web sizes. */
	@media (pointer: coarse) {
		.native-editor :global(div.rich-document .ProseMirror) {
			font: -apple-system-body;
			font-family: var(--font-sans);
			line-height: 1.6;
		}
		.native-editor :global(.rich-document h1) {
			font-size: min(1.8em, 1em + 12px);
		}
		.native-editor :global(.rich-document h2) {
			font-size: min(1.4em, 1em + 8px);
		}
		.native-editor :global(.rich-document h3) {
			font-size: min(1.15em, 1em + 4px);
		}
	}
	.native-editor :global(.markdown-editor) {
		border: 0;
		border-radius: 0;
	}
	.native-editor :global(.markdown-editor),
	.native-editor :global(.ProseMirror),
	.native-editor :global(textarea) {
		min-height: 100dvh;
	}
</style>
