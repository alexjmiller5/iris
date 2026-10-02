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
