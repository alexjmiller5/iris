<script lang="ts">
	import MarkdownEditor from './components/MarkdownEditor.svelte';
	import { parseEditorDocument, type EditorDocument, type EditorMessage } from './editor-island';
	import { editorFiles } from './editor-files';
	import { onDestroy } from 'svelte';
	let { onMessage }: { onMessage(message: EditorMessage): void } = $props();
	let current = $state<EditorDocument>({ id: 'initial', value: '', label: 'Body', readOnly: true });
	let announced = false;
	const files = editorFiles((message) => onMessage(message));
	onDestroy(() => files.dispose());
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
