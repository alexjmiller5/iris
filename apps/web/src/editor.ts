import { flushSync, mount } from 'svelte';
import EditorIsland from './lib/EditorIsland.svelte';
import type { EditorDocument, EditorMessage } from './lib/editor-island';
import './islands.css';

declare global {
	interface Window {
		lifeEditor: {
			setDocument(input: unknown): void;
			getDocument(): EditorDocument;
			receiveFile(input: unknown): void;
		};
	}
}
const host = window as Window & {
	webkit?: { messageHandlers?: { editor?: { postMessage(message: EditorMessage): void } } };
};
const editor = mount(EditorIsland, {
	target: document.body,
	props: {
		onMessage: (message: EditorMessage) =>
			host.webkit?.messageHandlers?.editor?.postMessage(message)
	}
});
window.lifeEditor = {
	setDocument: (input) => flushSync(() => editor.setDocument(input)),
	receiveFile: (input) => editor.receiveFile(input),
	getDocument: () => flushSync(() => editor.getDocument())
};
