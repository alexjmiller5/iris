<script lang="ts">
	import { onDestroy } from 'svelte';
	import { IconPaperclip } from '@tabler/icons-svelte';
	import { attachmentMarkdown, type AttachmentOutbox } from './attachments';
	let {
		outbox,
		value = '',
		disabled = false,
		onchange,
		property = false
	}: {
		outbox: AttachmentOutbox;
		value?: string;
		disabled?: boolean;
		onchange(value: string): void;
		property?: boolean;
	} = $props();
	let active = true;
	onDestroy(() => {
		active = false;
	});
	let input: HTMLInputElement;
	let staging = $state(false),
		error = $state(''),
		revision = $state(0);
	$effect(() => {
		const changed = () => revision++;
		outbox.addEventListener('change', changed);
		return () => outbox.removeEventListener('change', changed);
	});
	const pending = $derived.by(() => {
		revision;
		return outbox.entries.filter((e) => e.state !== 'uploaded');
	});
	const uploadError = $derived.by(() => {
		revision;
		return outbox.error;
	});
	const uploading = $derived.by(() => {
		revision;
		return outbox.busy;
	});
	async function select() {
		const file = input.files?.[0];
		if (!file || staging) return;
		staging = true;
		error = '';
		const owner = outbox;
		try {
			const entry = await owner.stage(file);
			if (active && outbox === owner && !disabled)
				onchange(property ? '/v1/files/' + entry.key : attachmentMarkdown(entry, value));
		} catch {
			if (!active) return;
			error = 'The file could not be kept. Check its size and available storage, then retry.';
		} finally {
			if (active) {
				staging = false;
				input.value = '';
			}
		}
	}
</script>

<div class="attachments">
	<button type="button" onclick={() => input.click()} disabled={disabled || staging}
		><IconPaperclip size={16} /> {staging ? 'Keeping file…' : 'Attach file'}</button
	>
	<input bind:this={input} type="file" aria-label="Choose attachment" onchange={select} hidden />
	{#if pending.length}
		<details>
			<summary>{pending.length} file(s) pending</summary>
			<ul>
				{#each pending as entry (entry.id)}<li>
						{entry.name}: {entry.state === 'failed'
							? 'Upload failed, bytes kept'
							: entry.state === 'uploading'
								? 'Uploading'
								: 'Kept on this device'}
					</li>{/each}
			</ul>
			<button type="button" disabled={uploading} onclick={() => outbox.retry()}
				>Retry uploads</button
			>
		</details>
	{/if}
	{#if error || uploadError}<p role="alert">{error || uploadError}</p>{/if}
</div>

<style>
	.attachments {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		flex-wrap: wrap;
		font-size: 0.8rem;
	}
	button {
		display: inline-flex;
		align-items: center;
		gap: 0.25rem;
		min-height: 44px;
	}
	summary {
		cursor: pointer;
	}
	p {
		width: 100%;
	}
</style>
