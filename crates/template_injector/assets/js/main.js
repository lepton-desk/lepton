// Generated from `main.ts` by tools/transpile-assets.mjs.
//
// Edit the TypeScript source, not this file: this one is rewritten on every run and
// an edit made here is lost without warning. Running the script in check mode is what
// keeps the two in step.

/**
 * The screen a Lepton project starts with: this machine, read through the shared
 * channel, once a second.
 *
 * It is not a demo. Every number on it was measured — the uptime by the kernel, the
 * resident set by reading the process's own status page, the ring occupancy by the
 * core's allocator, the round trip by a frame sent and waited for. A template that
 * showed invented figures would be teaching the wrong lesson twice: that numbers on
 * a screen can be made up, and that this framework's first job is to be pretty.
 *
 * Replace this file with your own application. `lepton.ts` stays: it is the binding
 * that gets you the channel.
 */
import { channel, measures } from "./lepton.js";
import { exceedsTolerance, rows } from "./measures.js";
import "./lepton-sdk.css";
/** How often the table is rebuilt, in milliseconds.
 *
 * Once a second because that is the rate at which these values change meaning: a
 * round-trip figure sampled every frame says something about the sampler, not about
 * the channel. Faster would be a number nobody can read; slower would hide a stall.
 */
const REFRESH_MS = 1000;
/**
 * The reading the table was last drawn from, so each row can show which way it moved.
 * Null until the first reading: no trend is better than a trend against nothing.
 */
let previous = null;
/**
 * The screen before the core has published anything.
 *
 * An empty forme with the same furniture, not a spinner and not zeroes: the layout is
 * known before the first measurement, and showing it empty says "nothing measured
 * yet", which is what is true.
 */
function renderWaiting() {
    const forme = document.createElement("div");
    forme.className = "forme forme--registered";
    const bay = document.createElement("main");
    bay.className = "bay";
    const title = document.createElement("h1");
    title.className = "bay__title";
    title.textContent = "this machine";
    bay.append(title);
    const table = document.createElement("table");
    table.className = "measures";
    const caption = document.createElement("caption");
    caption.textContent = "waiting for the core";
    table.append(caption);
    const body = document.createElement("tbody");
    const row = document.createElement("tr");
    const cell = document.createElement("td");
    cell.colSpan = 3;
    cell.textContent = "no reading yet";
    row.append(cell);
    body.append(row);
    table.append(body);
    bay.append(table);
    forme.append(bay);
    const app = document.querySelector("#app");
    if (app !== null) {
        app.replaceChildren(forme);
    }
}
/** One row as a `<tr>`, built with the DOM rather than an HTML string. */
function renderRow(row) {
    const tr = document.createElement("tr");
    const name = document.createElement("th");
    name.scope = "row";
    name.textContent = row.label;
    const value = document.createElement("td");
    value.className = "measures__value";
    value.textContent = row.value;
    value.title = row.exact;
    // The cast: a direction, or a tolerance mark, or nothing. Written as text rather
    // than as a glyph so a screen reader announces it.
    const cast = document.createElement("td");
    cast.className = "measures__cast";
    if (row.label === "round trip p50" && readingExceedsTolerance) {
        const mark = document.createElement("span");
        mark.className = "out-of-tolerance";
        mark.textContent = "out of tolerance";
        cast.append(mark);
    }
    else if (row.trend === "rising") {
        cast.textContent = "▲";
    }
    else if (row.trend === "falling") {
        cast.textContent = "▼";
    }
    tr.append(name, value, cast);
    return tr;
}
/** Whether the current reading is outside tolerance.
 *
 * A module-level flag rather than a value threaded through `rows` because the mark is
 * about the reading as a whole, and a helper that had to be handed it would be a
 * place for the two to disagree.
 */
let readingExceedsTolerance = false;
/** Builds the whole screen for one reading. */
function render(reading) {
    readingExceedsTolerance = exceedsTolerance(reading);
    const forme = document.createElement("div");
    forme.className = "forme forme--registered";
    const rail = document.createElement("nav");
    rail.className = "rail";
    rail.setAttribute("aria-label", "views");
    const label = document.createElement("div");
    label.className = "rail__label";
    label.textContent = "forme";
    rail.append(label);
    // One item, because there is one view. The rail is here so the layout of a real
    // application is already right: the second item is a button and nothing else
    // changes, which is the cheapest possible way to find out whether this was a good
    // structural decision.
    const item = document.createElement("button");
    item.className = "rail__item";
    item.type = "button";
    item.textContent = "measures";
    item.setAttribute("aria-current", "page");
    rail.append(item);
    const bay = document.createElement("main");
    bay.className = "bay";
    const title = document.createElement("h1");
    title.className = "bay__title";
    title.textContent = "this machine";
    bay.append(title);
    const table = document.createElement("table");
    table.className = "measures";
    const caption = document.createElement("caption");
    caption.textContent = "read through the shared channel";
    table.append(caption);
    const head = document.createElement("thead");
    const headRow = document.createElement("tr");
    for (const [text, sort] of [
        ["measure", null],
        ["value", null],
        ["", null],
    ]) {
        const cell = document.createElement("th");
        cell.scope = "col";
        cell.textContent = text;
        if (sort !== null) {
            cell.setAttribute("aria-sort", sort);
        }
        headRow.append(cell);
    }
    head.append(headRow);
    table.append(head);
    const body = document.createElement("tbody");
    for (const row of rows(reading, previous)) {
        body.append(renderRow(row));
    }
    table.append(body);
    bay.append(table);
    forme.append(rail, bay);
    // Replaced rather than emptied and refilled: a fresh subtree means the browser
    // never has to reconcile the old one, and a stale cell cannot survive a reading
    // that no longer has it.
    const app = document.querySelector("#app");
    if (app === null) {
        return;
    }
    app.replaceChildren(forme);
    previous = reading;
}
/**
 * Starts the screen.
 *
 * Called once and given a single reading to start from, so the window shows numbers
 * the instant it opens instead of an empty forme for up to a second. The core
 * publishes the current reading when the channel is created, so this is a real
 * measurement rather than a placeholder.
 */
function start() {
    const opening = channel.latest();
    if (opening.measures !== null) {
        render(opening.measures);
    }
    else {
        renderWaiting();
    }
    measures.subscribe((reading) => {
        render(reading);
    });
    // A heartbeat for the case where the core goes away without closing the window —
    // a crash, or a compositor that took the surface. The caption is the only thing
    // that changes, because the numbers would be stale and a stale number presented as
    // current is the one thing this screen must never do.
    window.setInterval(() => {
        const caption = document.querySelector("caption");
        if (caption !== null && !channel.isConnected()) {
            caption.textContent = "core not connected";
        }
    }, REFRESH_MS);
}
start();
