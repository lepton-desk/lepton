/**
 * The measures screen, in Angular.
 *
 * A view over `measures.ts` and nothing more: the arithmetic — which unit, how many digits,
 * whether an arrow is honest — lives there once, and this component decides how the result
 * is put on screen. The class names are the ones every other template uses, and
 * `lepton-sdk.css` is written against them.
 */

import { Component, computed, DestroyRef, inject, signal } from "@angular/core";
import { channel, type MeasureSet, measures } from "../lepton.ts";
import { exceedsTolerance, type Row, rows } from "../measures.ts";

@Component({
  selector: "app-root",
  template: `
    @if (current(); as reading) {
      <div class="forme forme--registered">
        <!-- The rail is here so the layout of a real application is already right: the
             second item is a button and nothing else changes. -->
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
              @for (row of table(); track row.label) {
                <tr>
                  <th scope="row">{{ row.label }}</th>
                  <td class="measures__value" [title]="row.exact">{{ row.value }}</td>
                  <!-- Written as text rather than as a glyph so a screen reader announces it. -->
                  <td class="measures__cast">
                    @if (tolerance() && row.label === "round trip p50") {
                      <span class="out-of-tolerance">out of tolerance</span>
                    } @else if (row.trend === "rising") {
                      ▲
                    } @else if (row.trend === "falling") {
                      ▼
                    }
                  </td>
                </tr>
              }
            </tbody>
          </table>
        </main>
      </div>
    } @else {
      <!-- The same furniture, empty: the layout is known before the first measurement. -->
      <div class="forme forme--registered">
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
    }
  `,
})
export class App {
  /** The newest reading, and the one before it: a trend compares the two. */
  protected readonly current = signal<MeasureSet | null>(channel.latest().measures);
  private readonly previous = signal<MeasureSet | null>(null);

  protected readonly table = computed((): Row[] => {
    const reading = this.current();
    return reading === null ? [] : rows(reading, this.previous());
  });

  protected readonly tolerance = computed((): boolean => {
    const reading = this.current();
    return reading !== null && exceedsTolerance(reading);
  });

  constructor() {
    const unsubscribe = measures.subscribe((reading) => {
      this.previous.set(this.current());
      this.current.set(reading);
    });
    inject(DestroyRef).onDestroy(unsubscribe);
  }
}
