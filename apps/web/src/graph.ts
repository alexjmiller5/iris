import { flushSync, mount } from 'svelte';
import GraphIsland from './lib/GraphIsland.svelte';
import type { GraphMessage } from './lib/graph-island';
import './islands.css';

declare global {
	interface Window {
		IrisGraph: { render(input: unknown): void };
		webkit?: { messageHandlers?: { irisGraph?: { postMessage(message: GraphMessage): void } } };
	}
}

const graph = mount(GraphIsland, {
	target: document.body,
	props: {
		onMessage: (message: GraphMessage) =>
			window.webkit?.messageHandlers?.irisGraph?.postMessage(message)
	}
});

// Native hosts call after navigation finishes, passing JSON through WebKit arguments.
window.IrisGraph = { render: (input) => flushSync(() => graph.render(input)) };
