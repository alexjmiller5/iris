<script lang="ts">
	import { IconTable } from '@tabler/icons-svelte';
	import type { Property, Row } from 'life-ui-core/client';
	import { layoutSchema } from './schema-graph';

	let {
		tables,
		properties,
		onSelect,
		groups = $bindable({})
	}: {
		tables: Row[];
		properties: Property[];
		onSelect: (table: string) => void;
		groups?: Record<string, string>;
	} = $props();
	const uid = $props.id();
	const graph = $derived(layoutSchema(tables, properties, groups));
	const orderedNodes = $derived([...graph.nodes].sort((a, b) => a.id.localeCompare(b.id)));
</script>

<section class="schema-graph" aria-label="Schema graph">
	<header>
		<div>
			<h2>Table relationships</h2>
			<p>Select a table to open its rows.</p>
		</div>
		<span class="count">{graph.nodes.length} tables · {graph.edges.length} relationships</span>
	</header>
	{#if !graph.nodes.length}
		<p class="empty">Sync a workspace to see its tables and relationships.</p>
	{:else}
		<div class="legend" aria-label="Relationship types">
			<span
				><svg width="28" height="12" aria-hidden="true"><path d="M 0 6 H 28" /></svg>Reference</span
			>
			<span
				><svg width="28" height="12" aria-hidden="true"
					><path d="M 0 6 H 28" stroke-dasharray="5 4" /></svg
				>Multiple references</span
			>
		</div>
		<!-- svelte-ignore a11y_no_noninteractive_tabindex (The scrollable diagram needs a keyboard focus target.) -->
		<div class="canvas" role="region" aria-label="Scrollable table graph" tabindex="0">
			<svg
				width={graph.width}
				height={graph.height}
				viewBox={`0 0 ${graph.width} ${graph.height}`}
				role="group"
				aria-labelledby={`${uid}-title`}
			>
				<title id={`${uid}-title`}>Catalog tables and reference relationships</title>
				<defs
					><marker
						id={`${uid}-arrow`}
						viewBox="0 0 10 10"
						refX="9"
						refY="5"
						markerWidth="6"
						markerHeight="6"
						orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 Z" class="arrow" /></marker
					></defs
				>
				{#each graph.groups as group (group.id)}
					<rect
						class="band"
						x="1"
						y={group.y + 1}
						width={graph.width - 2}
						height={group.height - 2}
						rx="8"
					/>
					<text class="group-name" x="24" y={group.y + 30}>{group.name}</text>
				{/each}
				{#each graph.edges as edge (edge.id)}
					<g class="relationship"
						><title
							>{edge.source}.{edge.column} references {edge.target}{edge.many
								? ' (multiple)'
								: ''}</title
						>
						<path
							d={edge.path}
							stroke-dasharray={edge.many ? '5 4' : undefined}
							marker-end={`url(#${uid}-arrow)`}
						/>
						<text x={edge.x} y={edge.y} text-anchor="middle">{edge.label}</text>
					</g>
				{/each}
				{#each graph.nodes as node (node.id)}
					<foreignObject x={node.x} y={node.y} width={node.width} height={node.height}>
						<button
							type="button"
							class="table-node"
							aria-label={`Open table ${node.id}`}
							onclick={() => onSelect(node.id)}
						>
							<IconTable size={21} aria-hidden="true" />
							<span
								><strong title={node.id}>{node.id}</strong><small
									>{node.columns} {node.columns === 1 ? 'column' : 'columns'}</small
								></span
							>
						</button>
					</foreignObject>
				{/each}
			</svg>
		</div>
		{#if !graph.edges.length}<p class="hint">
				No reference relationships are defined in this catalog.
			</p>{/if}
		<details class="groups">
			<summary>Group tables</summary>
			<p>Use the same group name to keep tables together. Grouping only changes this view.</p>
			<div class="group-fields">
				{#each orderedNodes as node (node.id)}
					<label
						><span>{node.id}</span><input
							aria-label={`Group for ${node.id}`}
							value={groups[node.id] ?? ''}
							placeholder="Ungrouped"
							maxlength="60"
							onchange={(event) =>
								(groups = { ...groups, [node.id]: event.currentTarget.value.trim() })}
						/></label
					>
				{/each}
			</div>
		</details>
		{#if graph.edges.length}
			<details class="relationships">
				<summary>Relationship details ({graph.edges.length})</summary>
				<ul>
					{#each graph.edges as edge (edge.id)}<li>
							<button type="button" onclick={() => onSelect(edge.source)}>{edge.source}</button
							><span>{edge.label} references</span><button
								type="button"
								onclick={() => onSelect(edge.target)}>{edge.target}</button
							>{#if edge.many}<span class="hint">(multiple)</span>{/if}
						</li>{/each}
				</ul>
			</details>
		{/if}
	{/if}
</section>

<style>
	.schema-graph {
		min-width: 0;
		max-width: 100%;
		color: var(--color-ink);
	}
	header {
		display: flex;
		align-items: start;
		justify-content: space-between;
		flex-wrap: wrap;
		gap: 12px;
		margin-bottom: 20px;
	}
	h2 {
		margin: 0 0 6px;
		font-size: 20px;
		font-weight: 600;
		letter-spacing: -0.3px;
	}
	header p,
	.count,
	.hint,
	.groups p {
		color: var(--color-muted);
		font-size: 13px;
		line-height: 1.6;
		margin: 0;
	}
	.count {
		padding-top: 4px;
	}
	.legend {
		display: flex;
		flex-wrap: wrap;
		gap: 20px;
		margin-bottom: 14px;
		color: var(--color-muted);
		font-size: 12px;
	}
	.legend span {
		display: inline-flex;
		align-items: center;
		gap: 8px;
	}
	.legend path,
	.relationship path {
		fill: none;
		stroke: var(--color-muted);
		stroke-width: 1.5;
	}
	.canvas {
		max-width: 100%;
		max-height: min(68vh, 680px);
		overflow: auto;
		padding: 4px;
		border-radius: 8px;
	}
	.canvas > svg {
		display: block;
	}
	.band {
		fill: var(--color-bone);
		stroke: var(--color-rule);
	}
	.group-name {
		fill: var(--color-muted);
		font-size: 13px;
		font-weight: 600;
	}
	.arrow {
		fill: var(--color-muted);
	}
	.relationship text {
		fill: var(--color-muted);
		font-size: 12px;
		paint-order: stroke;
		stroke: var(--color-bone);
		stroke-width: 5px;
		stroke-linejoin: round;
	}
	.table-node {
		width: 100%;
		height: 100%;
		min-height: 44px;
		padding: 12px 16px;
		display: flex;
		align-items: center;
		gap: 12px;
		text-align: left;
		color: var(--color-ink);
		background: var(--color-paper);
		border: 1px solid var(--color-rule);
		border-radius: 7px;
		cursor: pointer;
		font: inherit;
	}
	.table-node:hover {
		border-color: var(--color-accent);
		background: var(--color-accent-soft);
	}
	.table-node:focus-visible {
		outline: 3px solid var(--color-accent);
		outline-offset: -4px;
	}
	.table-node :global(svg) {
		flex-shrink: 0;
		color: var(--color-accent);
	}
	.table-node span {
		min-width: 0;
	}
	.table-node strong {
		display: block;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		font-size: 14px;
		font-weight: 600;
	}
	.table-node small {
		display: block;
		margin-top: 5px;
		color: var(--color-muted);
		font-size: 12px;
		font-weight: 400;
	}
	details {
		border-top: 1px solid var(--color-rule);
		margin-top: 20px;
		padding-top: 16px;
		font-size: 13px;
	}
	summary {
		cursor: pointer;
		min-height: 36px;
		font-weight: 600;
	}
	.group-fields {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(min(100%, 230px), 1fr));
		gap: 16px;
		margin-top: 16px;
	}
	.group-fields label {
		display: grid;
		gap: 6px;
		margin: 0;
		min-width: 0;
		font-size: 13px;
	}
	.group-fields label span {
		overflow-wrap: anywhere;
	}
	.group-fields input {
		width: 100%;
		min-width: 0;
		min-height: 40px;
		font: inherit;
	}
	.relationships ul {
		list-style: none;
		padding: 0;
		margin: 0;
	}
	.relationships li {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 6px;
		padding: 5px 0;
	}
	.relationships button {
		padding: 4px 0;
		min-height: 36px;
		color: var(--color-accent);
		background: none;
		border: 0;
		font: inherit;
		font-weight: 600;
		overflow-wrap: anywhere;
		text-align: left;
		cursor: pointer;
	}
	.empty {
		padding: 40px 20px;
		border: 1px solid var(--color-rule);
		border-radius: 8px;
		text-align: center;
		color: var(--color-muted);
		font-size: 14px;
		line-height: 1.6;
	}
</style>
