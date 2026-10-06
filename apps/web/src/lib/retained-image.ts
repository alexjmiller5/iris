import type { Node } from '@milkdown/kit/prose/model';
import {
	retainedFileKey,
	isInlineImage,
	type RetainedFileResolver,
	type RetainedFile
} from './retained-files';

/** A node view changes presentation only. No ProseMirror transactions or source rewrites. */
export function retainedImage(node: Node, resolve?: RetainedFileResolver) {
	const dom = document.createElement('span');
	dom.dataset.type = 'image-reference';
	dom.contentEditable = 'false';
	const label = node.attrs.alt || 'Image reference';
	dom.setAttribute('role', 'img');
	dom.setAttribute('aria-label', label);
	const key = retainedFileKey(String(node.attrs.src ?? ''));
	let stopped = false,
		file: RetainedFile | undefined;
	const controller = new AbortController();
	async function load() {
		if (!key || !resolve || stopped) return;
		dom.textContent = `Loading ${label}…`;
		try {
			const result = await resolve(key, controller.signal, true);
			if (stopped) {
				result.dispose();
				return;
			}
			file?.dispose();
			file = result;
			if (!isInlineImage(result.contentType) || !result.url.startsWith('blob:')) {
				throw Error('This file cannot be displayed as an image.');
			}
			const image = document.createElement('img');
			image.alt = label;
			image.src = result.url;
			image.onerror = () => failed('The image could not be decoded.');
			dom.dataset.type = 'retained-image';
			dom.replaceChildren(image);
		} catch (error) {
			if (!stopped) failed(error instanceof Error ? error.message : 'Image unavailable.');
		}
	}
	function failed(message: string) {
		file?.dispose();
		file = undefined;
		dom.dataset.type = 'image-reference';
		const reason = document.createElement('span');
		reason.textContent = `${label}: ${message} `;
		const retry = document.createElement('button');
		retry.type = 'button';
		retry.textContent = 'Retry image';
		retry.onclick = () => void load();
		dom.replaceChildren(reason, retry);
	}
	dom.textContent = label;
	void load();
	return {
		dom,
		stopEvent: () => true,
		ignoreMutation: () => true,
		destroy() {
			stopped = true;
			controller.abort();
			file?.dispose();
		}
	};
}
