// Generated from `solid/App.tsx` by tools/transpile-assets.mjs.
//
// Edit the TypeScript source, not this file: this one is rewritten on every run and
// an edit made here is lost without warning. Running the script in check mode is what
// keeps the two in step.

/**
 * The measures screen, in Solid.
 *
 * A view over `measures.ts` and nothing more, like the React and plain-DOM screens: the
 * arithmetic lives there once, and the class names are the ones `lepton-sdk.css` is
 * written against. Two readings are kept, because a trend compares a value with the one
 * before it.
 */
import { createMemo, createSignal, For, onCleanup, Show } from "solid-js";
import { channel, measures } from "./lepton.js";
import { exceedsTolerance, rows } from "./measures.js";

/** The third column: the trend as an arrow. */
function cast(row) {
  if (row.trend === "rising") return "▲";
  if (row.trend === "falling") return "▼";
  return "";
}
export function App() {
  const [current, setCurrent] = createSignal(channel.latest().measures);
  const [before, setBefore] = createSignal(null);
  onCleanup(
    measures.subscribe((reading) => {
      if (reading === current()) return;
      setBefore(current());
      setCurrent(reading);
    }),
  );
  const table = createMemo(() => {
    const reading = current();
    return reading === null ? [] : rows(reading, before());
  });
  const tolerance = createMemo(() => {
    const reading = current();
    return reading !== null && exceedsTolerance(reading);
  });
  return (
    <Show
      when={current() !== null}
      fallback={
        <div class="forme forme--registered">
          <main class="bay">
            <h1 class="bay__title">this machine</h1>
            <table class="measures">
              <caption>waiting for the core</caption>
              <tbody>
                <tr>
                  <td colSpan={3}>no reading yet</td>
                </tr>
              </tbody>
            </table>
          </main>
        </div>
      }
    >
      <div class="forme forme--registered">
        <nav class="rail" aria-label="views">
          <div class="rail__label">forme</div>
          <button class="rail__item" type="button" aria-current="page">
            measures
          </button>
        </nav>
        <main class="bay">
          <h1 class="bay__title">this machine</h1>
          <table class="measures">
            <caption>read through the shared channel</caption>
            <thead>
              <tr>
                <th scope="col">measure</th>
                <th scope="col">value</th>
                <th scope="col" />
              </tr>
            </thead>
            <tbody>
              <For each={table()}>
                {(row) => (
                  <tr>
                    <th scope="row">{row.label}</th>
                    <td class="measures__value" title={row.exact}>
                      {row.value}
                    </td>
                    <td class="measures__cast">
                      <Show
                        when={tolerance() && row.label === "round trip p50"}
                        fallback={cast(row)}
                      >
                        <span class="out-of-tolerance">out of tolerance</span>
                      </Show>
                    </td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </main>
      </div>
    </Show>
  );
}
