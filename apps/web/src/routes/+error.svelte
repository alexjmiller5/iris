<script lang="ts">
	import { page } from '$app/state';
</script>

<svelte:head><title>{page.status} - Iris</title></svelte:head>
<main class="grid min-h-svh place-content-center gap-4 p-6 text-center">
	<h1>{page.status}</h1>
	<p>{page.error?.message ?? 'Something went wrong.'}</p>
	<a href="/" class="text-accent underline">Back to Iris</a>
</main>
