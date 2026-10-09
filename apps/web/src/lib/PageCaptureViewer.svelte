<script lang="ts">
	import { onDestroy, tick } from 'svelte';
	import {
		parseCapture,
		readCaptureArtifact,
		archiveDocument,
		checkCapturePNG,
		CAPTURE_PREVIEW_LIMIT,
		CAPTURE_DOWNLOAD_LIMIT,
		type PageCapture,
		type CaptureKind
	} from './page-capture';
	import type { RetainedFileResolver } from './retained-files';
	let {
		row,
		resolveFile,
		disabled = false
	}: {
		row: Record<string, unknown>;
		resolveFile?: RetainedFileResolver;
		disabled?: boolean;
	} = $props();
	let dialog: HTMLDialogElement;
	let capture = $state<PageCapture | null>(null),
		error = $state(''),
		loading = $state(false);
	let kind = $state<CaptureKind>('png'),
		image = $state(''),
		html = $state('');
	let request: AbortController | undefined;
	let active = false;
	function release() {
		request?.abort();
		request = undefined;
		if (image) URL.revokeObjectURL(image);
		image = '';
		html = '';
		loading = false;
	}
	function close() {
		active = false;
		release();
		capture = null;
		dialog?.close();
	}
	onDestroy(close);
	async function open() {
		release();
		error = '';
		kind = 'png';
		try {
			capture = parseCapture({ ...row });
		} catch (e) {
			error = (e as Error).message;
			capture = null;
		}
		active = true;
		await tick();
		dialog.showModal();
		if (capture?.artifacts.png) await preview('png');
	}
	async function artifact(selected: CaptureKind, preview: boolean, signal: AbortSignal) {
		if (!capture || !resolveFile)
			throw Error('Connect to the hub with file access to read this artifact.');
		return await readCaptureArtifact(
			capture,
			selected,
			resolveFile,
			signal,
			preview ? CAPTURE_PREVIEW_LIMIT : CAPTURE_DOWNLOAD_LIMIT
		);
	}
	async function preview(selected: CaptureKind) {
		release();
		error = '';
		kind = selected;
		loading = true;
		const controller = new AbortController();
		request = controller;
		try {
			const blob = await artifact(selected, true, controller.signal);
			if (!active || controller.signal.aborted) return;
			if (selected === 'png') {
				await checkCapturePNG(blob);
				if (active && !controller.signal.aborted) image = URL.createObjectURL(blob);
			} else {
				const text = await blob.text();
				if (active && !controller.signal.aborted) html = archiveDocument(inertArchive(text));
			}
		} catch (e) {
			if (active && !controller.signal.aborted) error = (e as Error).message;
		} finally {
			if (active && !controller.signal.aborted) loading = false;
		}
	}
	// Empty sandbox/CSP block execution and subresources. Remove navigation surfaces
	// as well: browsers may follow a same-frame link even with default-src 'none'.
	function inertArchive(text: string) {
		const template = document.createElement('template');
		template.innerHTML = text;
		for (const node of template.content.querySelectorAll(
			'script,meta,base,link,iframe,frame,object,embed,template,animate,animateMotion,animateTransform,set'
		))
			node.remove();
		for (const node of template.content.querySelectorAll('*'))
			for (const attribute of [...node.attributes]) {
				if (
					attribute.name.toLowerCase().startsWith('on') ||
					['href', 'xlink:href', 'action', 'formaction', 'target', 'download', 'ping'].includes(
						attribute.name.toLowerCase()
					)
				)
					node.removeAttribute(attribute.name);
			}
		return template.innerHTML;
	}
	async function save(selected: CaptureKind) {
		request?.abort();
		error = '';
		loading = true;
		const controller = new AbortController();
		request = controller;
		try {
			const blob = await artifact(selected, false, controller.signal);
			if (!active || controller.signal.aborted) return;
			const url = URL.createObjectURL(blob);
			const anchor = document.createElement('a');
			anchor.href = url;
			anchor.download = `page.${selected}`;
			anchor.click();
			setTimeout(() => URL.revokeObjectURL(url), 1000);
		} catch (e) {
			if (active && !controller.signal.aborted) error = (e as Error).message;
		} finally {
			if (active && !controller.signal.aborted) loading = false;
		}
	}
</script>

<button type="button" class="secondary" {disabled} onclick={open}>View page capture</button>
<dialog
	bind:this={dialog}
	onclose={() => {
		if (!dialog.open) close();
	}}
	oncancel={close}
	aria-label="Page capture"
>
	<header>
		<h2>Page capture</h2>
		<button type="button" class="secondary" onclick={close}>Done</button>
	</header>
	{#if capture}
		<p><strong>{capture.status}</strong> · Attempted {capture.attemptedAt}</p>
		{#if capture.capturedAt}<p>Captured {capture.capturedAt}</p>{/if}
		<p class="url">{capture.originalURL}</p>
		{#if capture.warning}<p role="status">{capture.warning}</p>{/if}
		{#if capture.failure}<p>{capture.failure}</p>{/if}
		{#if capture.artifacts.png}
			<div class="actions">
				<button
					type="button"
					disabled={loading}
					aria-pressed={kind === 'png'}
					onclick={() => preview('png')}>Screenshot</button
				>
				<button
					type="button"
					disabled={loading}
					aria-pressed={kind === 'html'}
					onclick={() => preview('html')}>Archived HTML</button
				>
			</div>
			{#if image}<img src={image} alt="Captured page screenshot" />{/if}
			{#if html}<iframe title="Archived page" sandbox="" referrerpolicy="no-referrer" srcdoc={html}
				></iframe>{/if}
			{#if loading}<p role="status">Preparing capture…</p>{/if}
			<p class="hint">
				Preview limit: 8 MiB. Archived links and network requests are disabled. Larger originals
				remain available to save, up to 128 MiB.
			</p>
			<div class="actions">
				<button
					type="button"
					disabled={loading || capture.artifacts.png.bytes > CAPTURE_DOWNLOAD_LIMIT}
					onclick={() => save('png')}>Save PNG</button
				>
				<button
					type="button"
					disabled={loading || (capture.artifacts.html?.bytes ?? Infinity) > CAPTURE_DOWNLOAD_LIMIT}
					onclick={() => save('html')}>Save HTML</button
				>
			</div>
		{/if}
		{#if capture.sourceURL}<p>
				<a href={capture.sourceURL} target="_blank" rel="noopener noreferrer"
					>Open original website</a
				>
			</p>{/if}
		<details>
			<summary>Attempt details</summary>
			<p>{capture.id}</p>
			<p>{capture.sourceTable} / {capture.sourceRow} / {capture.sourceColumn}</p>
		</details>
	{/if}
	{#if error}<p role="alert">{error}</p>{/if}
</dialog>

<style>
	dialog {
		width: min(60rem, 95vw);
		max-height: 90vh;
		overflow: auto;
		border: 1px solid var(--color-rule, #ccc);
		border-radius: 0.75rem;
		padding: 1.5rem;
		background: var(--color-paper, #fff);
		color: var(--color-ink, #111);
		margin: auto;
	}
	dialog::backdrop {
		background: #0008;
	}
	header,
	.actions {
		display: flex;
		align-items: center;
		gap: 0.75rem;
		flex-wrap: wrap;
	}
	header {
		justify-content: space-between;
	}
	.url,
	details {
		overflow-wrap: anywhere;
	}
	img {
		max-width: 100%;
		max-height: 65vh;
		object-fit: contain;
	}
	iframe {
		width: 100%;
		height: 60vh;
		border: 1px solid #ccc;
		background: white;
	}
	.hint {
		font-size: 0.875rem;
	}
	h2 {
		font-size: 1.4rem;
		font-weight: 600;
	}
	p {
		margin: 0.6rem 0;
	}
	button {
		font: inherit;
		font-size: 0.875rem;
		border: 1px solid var(--color-rule, #ccc);
		padding: 0.5rem 0.75rem;
		border-radius: 0.375rem;
		background: var(--color-paper, #fff);
		cursor: pointer;
	}
	button:hover:not(:disabled),
	button[aria-pressed='true'] {
		background: var(--color-ink, #222);
		color: var(--color-paper, #fff);
	}
	button:disabled {
		opacity: 0.5;
		cursor: default;
	}
	button:focus-visible,
	a:focus-visible {
		outline: 2px solid var(--color-accent, #2463eb);
		outline-offset: 2px;
	}
	.actions {
		margin: 0.8rem 0;
	}
	a {
		text-decoration: underline;
		text-underline-offset: 0.2em;
	}
	details {
		margin-top: 1rem;
		font-size: 0.875rem;
	}
	[role='alert'] {
		color: var(--color-violation);
	}
</style>
