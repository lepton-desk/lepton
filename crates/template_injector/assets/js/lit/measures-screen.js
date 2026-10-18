// Generated from `lit/measures-screen.ts` by tools/transpile-assets.mjs.
//
// Edit the TypeScript source, not this file: this one is rewritten on every run and
// an edit made here is lost without warning. Running the script in check mode is what
// keeps the two in step.

/**
 * The measures screen, in Lit: a `<measures-screen>` element.
 *
 * A view over `measures.ts` and nothing more, like the React and plain-DOM screens: the
 * arithmetic lives there once, and the class names are the ones `lepton-sdk.css` is
 * written against. It renders into the page's own DOM rather than a shadow root, because a
 * shadow root would keep that stylesheet out. Written without decorators, so the same
 * class is plain JavaScript in a JavaScript project.
 */
import { html, LitElement } from "lit";
import { channel, measures } from "./lepton.js";
import { exceedsTolerance, rows } from "./measures.js";

/** The third column: an out-of-tolerance mark, or the trend as an arrow. */
function cast(row, tolerance) {
  if (tolerance && row.label === "round trip p50") {
    return html`<span class="out-of-tolerance">out of tolerance</span>`;
  }
  if (row.trend === "rising") return "▲";
  if (row.trend === "falling") return "▼";
  return "";
}
export class MeasuresScreen extends LitElement {
  /** Two readings: a trend compares a value with the one before it. (`before` would be
   *  taken: every element already has a `before()` method.) */
  latest = channel.latest().measures;
  previous = null;
  stop = null;
  createRenderRoot() {
    return this;
  }
  connectedCallback() {
    super.connectedCallback();
    this.stop = measures.subscribe((reading) => {
      if (reading === this.latest) return;
      this.previous = this.latest;
      this.latest = reading;
      this.requestUpdate();
    });
  }
  disconnectedCallback() {
    this.stop?.();
    this.stop = null;
    super.disconnectedCallback();
  }
  render() {
    const reading = this.latest;
    if (reading === null) {
      return html`<div class="forme forme--registered">
        <main class="bay">
          <h1 class="bay__title">this machine</h1>
          <table class="measures">
            <caption>waiting for the core</caption>
            <tbody>
              <tr><td colspan="3">no reading yet</td></tr>
            </tbody>
          </table>
        </main>
      </div>`;
    }
    const tolerance = exceedsTolerance(reading);
    return html`<div class="forme forme--registered">
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
            ${rows(reading, this.previous).map(
              (row) => html`<tr>
                <th scope="row">${row.label}</th>
                <td class="measures__value" title=${row.exact}>${row.value}</td>
                <td class="measures__cast">${cast(row, tolerance)}</td>
              </tr>`,
            )}
          </tbody>
        </table>
      </main>
    </div>`;
  }
}
customElements.define("measures-screen", MeasuresScreen);
