<script lang="ts">
	import MarkdownEditor from './components/MarkdownEditor.svelte';
	import { parseEditorDocument, type EditorDocument, type EditorMessage } from './editor-island';
	let { onMessage }: { onMessage(message: EditorMessage): void } = $props();
	let current = $state<EditorDocument>({ id: 'initial', value: '', label: 'Body', readOnly: true });
	let announced = false;
	export function setDocument(input: unknown) {
		current = parseEditorDocument(input);
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
