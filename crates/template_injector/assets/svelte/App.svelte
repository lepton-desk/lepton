<!--
  The measures screen, in Svelte 5.

  A view over `measures.ts` and nothing more, like the React and plain-DOM screens: the
  arithmetic lives there once, and the class names are the ones `lepton-sdk.css` is
  written against. Two readings are kept, because a trend compares a value with the one
  before it. `$state.raw`: a reading is replaced whole, never mutated, so it needs no
  deep proxy.
-->
<script lang="ts">
  import { onDestroy } from "svelte";
  import { channel, type MeasureSet, measures } from "./lepton.ts";
  import { exceedsTolerance, type Row, rows } from "./measures.ts";

  let current = $state.raw<MeasureSet | null>(channel.latest().measures);
  let before = $state.raw<MeasureSet | null>(null);

  const stop = measures.subscribe((reading) => {
    if (reading === current) return;
    before = current;
    current = reading;
  });
  onDestroy(stop);

  const table = $derived<Row[]>(current === null ? [] : rows(current, before));
  const tolerance = $derived(current !== null && exceedsTolerance(current));

  /** The third column: the trend as an arrow. */
  function cast(row: Row): string {
    if (row.trend === "rising") return "▲";
    if (row.trend === "falling") return "▼";
    return "";
  }
</script>

{#if current === null}
  <div class="forme forme--registered">
    <main class="bay">
      <h1 class="bay__title">this machine</h1>
      <table class="measures">
        <caption>waiting for the core</caption>
        <tbody>
          <tr><td colspan="3">no reading yet</td></tr>
        </tbody>
      </table>
    </main>
  </div>
{:else}
  <div class="forme forme--registered">
    <nav class="rail" aria-label="views">
      <div class="rail__label">forme</div>
      <button class="rail__item" type="button" aria-current="page">measures</button>
    </nav>
    <main class="bay">
      <h1 class="bay__title">this machine</h1>
      <table class="measures">
        <caption>read through the shared channel</caption>
        <thead>
          <tr>
            <th scope="col">measure</th>
            <th scope="col">value</th>
            <th scope="col"></th>
          </tr>
        </thead>
        <tbody>
          {#each table as row (row.label)}
            <tr>
              <th scope="row">{row.label}</th>
              <td class="measures__value" title={row.exact}>{row.value}</td>
              <td class="measures__cast">
                {#if tolerance && row.label === "round trip p50"}
                  <span class="out-of-tolerance">out of tolerance</span>
                {:else}
                  {cast(row)}
                {/if}
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </main>
  </div>
{/if}
