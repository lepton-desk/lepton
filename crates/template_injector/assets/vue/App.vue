<!--
  The measures screen, in Vue.

  A view over `measures.ts` and nothing more, like the React and plain-DOM screens: the
  arithmetic lives there once, and the class names are the ones `lepton-sdk.css` is
  written against. Two readings are kept, because a trend compares a value with the one
  before it.
-->
<script setup lang="ts">
import { computed, onBeforeUnmount, shallowRef } from "vue";
import { channel, type MeasureSet, measures } from "./lepton.ts";
import { exceedsTolerance, type Row, rows } from "./measures.ts";

const current = shallowRef<MeasureSet | null>(channel.latest().measures);
const before = shallowRef<MeasureSet | null>(null);

const stop = measures.subscribe((reading) => {
  if (reading === current.value) return;
  before.value = current.value;
  current.value = reading;
});
onBeforeUnmount(stop);

const table = computed<Row[]>(() =>
  current.value === null ? [] : rows(current.value, before.value),
);
const tolerance = computed(() => current.value !== null && exceedsTolerance(current.value));

/** The third column: an out-of-tolerance mark, or the trend as an arrow. */
function cast(row: Row): string {
  if (row.trend === "rising") return "▲";
  if (row.trend === "falling") return "▼";
  return "";
}
</script>

<template>
  <div v-if="current === null" class="forme forme--registered">
    <main class="bay">
      <h1 class="bay__title">this machine</h1>
      <table class="measures">
        <caption>waiting for the core</caption>
        <tbody>
          <tr>
            <td colspan="3">no reading yet</td>
          </tr>
        </tbody>
      </table>
    </main>
  </div>
  <div v-else class="forme forme--registered">
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
          <tr v-for="row in table" :key="row.label">
            <th scope="row">{{ row.label }}</th>
            <td class="measures__value" :title="row.exact">{{ row.value }}</td>
            <td class="measures__cast">
              <span v-if="tolerance && row.label === 'round trip p50'" class="out-of-tolerance">
                out of tolerance
              </span>
              <template v-else>{{ cast(row) }}</template>
            </td>
          </tr>
        </tbody>
      </table>
    </main>
  </div>
</template>
