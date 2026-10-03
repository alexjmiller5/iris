import { flushSync, mount } from 'svelte';
import GraphIsland from './lib/GraphIsland.svelte';
import type { GraphMessage } from './lib/graph-island';
import './islands.css';

declare global {
	interface Window {
		LifeGraph: { render(input: unknown): void };
		webkit?: { messageHandlers?: { lifeGraph?: { postMessage(message: GraphMessage): void } } };
	}
}

const graph = mount(GraphIsland, {
	target: document.body,
	props: {
		onMessage: (message: GraphMessage) =>
			window.webkit?.messageHandlers?.lifeGraph?.postMessage(message)
	}
});

// Native hosts call after navigation finishes, passing JSON through WebKit arguments.
window.LifeGraph = { render: (input) => flushSync(() => graph.render(input)) };
