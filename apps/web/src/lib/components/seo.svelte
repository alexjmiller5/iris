<script lang="ts">
	import { page } from '$app/state';

	// One component = every route's head basics. Use on EVERY route:
	//   <Seo title="..." description="..." image="/og.png" />
	// image is an absolute path to a 1200x630 banner (og:image); omit until
	// the site has one.
	let { title, description, image }: { title: string; description: string; image?: string } =
		$props();
</script>

<svelte:head>
	<title>{title}</title>
	<meta name="description" content={description} />
	<meta property="og:type" content="website" />
	<meta property="og:title" content={title} />
	<meta property="og:description" content={description} />
	<meta property="og:url" content={page.url.href} />
	{#if image}
		<meta property="og:image" content={new URL(image, page.url.origin).href} />
		<meta name="twitter:card" content="summary_large_image" />
	{:else}
		<meta name="twitter:card" content="summary" />
	{/if}
</svelte:head>
