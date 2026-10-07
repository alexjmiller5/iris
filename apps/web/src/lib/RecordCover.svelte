<script lang="ts">
	import { retainedFileKey, type RetainedFileResolver } from './retained-files';
	let {
		value,
		label,
		resolveFile
	}: { value: unknown; label: string; resolveFile?: RetainedFileResolver } = $props();
	let source = $state(''),
		failed = $state(false);
	$effect(() => {
		let raw = value;
		if (typeof raw === 'string' && raw.startsWith('[')) {
			try {
				raw = JSON.parse(raw);
			} catch {
				raw = null;
			}
		}
		if (Array.isArray(raw)) raw = raw.find((v) => typeof v === 'string' && v.length);
		source = '';
		failed = false;
		if (typeof raw !== 'string') return;
		const key = retainedFileKey(raw),
			controller = new AbortController();
		let disposed = false,
			release: (() => void) | undefined;
		if (key && resolveFile) {
			resolveFile(key, controller.signal, true)
				.then((file) => {
					if (disposed) {
						file.dispose();
						return;
					}
					release = file.dispose;
					source = file.url;
				})
				.catch(() => {
					if (!disposed) failed = true;
				});
		} else if (/^https:\/\//i.test(raw)) {
			try {
				const url = new URL(raw);
				if (!url.username && !url.password) source = url.href;
			} catch {
				failed = true;
			}
		}
		return () => {
			disposed = true;
			controller.abort();
			release?.();
		};
	});
</script>

<div class="cover">
	{#if source && !failed}<img
			src={source}
			alt={label}
			referrerpolicy="no-referrer"
			loading="lazy"
			onerror={() => (failed = true)}
		/>
	{:else}<span>{failed ? 'Cover unavailable' : 'No cover'}</span>{/if}
</div>

<style>
	.cover {
		aspect-ratio: 16/10;
		background: var(--color-bone);
		display: grid;
		place-items: center;
		overflow: hidden;
		border-radius: 8px 8px 0 0;
		color: var(--color-muted);
		font-size: 0.8rem;
	}
	img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}
</style>
