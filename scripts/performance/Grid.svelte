<script lang="ts">
  import { onMount } from "svelte";
  import RecordGrid from "../../apps/web/src/lib/RecordGrid.svelte";
  const rows = Array.from({ length: 10000 }, (_, i) => ({
    id: `r${i}`,
    title: `Record ${i}`,
    quantity: i,
  }));
  const properties = [
    { col: "title", label: "Title" },
    { col: "quantity", label: "Quantity", type: "int" },
  ];
  let ready = $state(false);
  onMount(() => {
    ready = true;
  });
</script>

<main data-iris-performance="10000">
  <h1>Synthetic grid render measurement</h1>
  <p>
    10,000 in-memory rows. This fixture does not measure SQLite or replica boot.
  </p>
  {#if ready}
    <RecordGrid
      {rows}
      {properties}
      widths={{ quantity: 96 }}
      busy={false}
      canCreate={false}
      format={(_, value) => String(value ?? "")}
      canEdit={() => false}
      onbegin={async () => false}
      oncommit={async (draft) => draft.baseline}
      onopen={async () => false}
      onnew={async () => false}
      onduplicate={async () => false}
    />
  {/if}
</main>
