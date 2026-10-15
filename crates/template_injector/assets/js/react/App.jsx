// Generated from `react/App.tsx` by tools/transpile-assets.mjs.
//
// Edit the TypeScript source, not this file: this one is rewritten on every run and
// an edit made here is lost without warning. Running the script in check mode is what
// keeps the two in step.

import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
/**
 * The measures screen, in React.
 *
 * A view over `measures.ts` and nothing more: the arithmetic — which unit, how many
 * digits, whether an arrow is honest — lives there once, and this file decides how the
 * result is put on screen. That split is what makes a second framework a matter of
 * writing a second view rather than a second measurement.
 *
 * The class names are the same ones the plain-DOM screen uses, and `lepton-sdk.css` is
 * written against them. The alternative — a React-specific stylesheet — would mean a
 * second visual language for the same window, and a framework is a choice about how
 * state is expressed, not about how the application looks.
 */
import { useState } from "react";
import { exceedsTolerance, rows } from "./measures.js";
/** Shown before the core has published anything.
 *
 * The same furniture, empty, rather than a spinner or zeroes: the layout is known before
 * the first measurement, and showing it empty says "nothing measured yet", which is what
 * is true.
 */
function Waiting() {
    return (_jsx("div", { className: "forme forme--registered", children: _jsxs("main", { className: "bay", children: [_jsx("h1", { className: "bay__title", children: "this machine" }), _jsxs("table", { className: "measures", children: [_jsx("caption", { children: "waiting for the core" }), _jsx("tbody", { children: _jsx("tr", { children: _jsx("td", { colSpan: 3, children: "no reading yet" }) }) })] })] }) }));
}
/** One row, as a `<tr>`. */
function Row_({ row, tolerance }) {
    const cast = tolerance && row.label === "round trip p50" ? (_jsx("span", { className: "out-of-tolerance", children: "out of tolerance" })) : row.trend === "rising" ? ("▲") : row.trend === "falling" ? ("▼") : null;
    return (_jsxs("tr", { children: [_jsx("th", { scope: "row", children: row.label }), _jsx("td", { className: "measures__value", title: row.exact, children: row.value }), _jsx("td", { className: "measures__cast", children: cast })] }));
}
/** The table for one reading. */
function Measures({ reading, previous, }) {
    const tolerance = exceedsTolerance(reading);
    return (_jsxs("div", { className: "forme forme--registered", children: [_jsxs("nav", { className: "rail", "aria-label": "views", children: [_jsx("div", { className: "rail__label", children: "forme" }), _jsx("button", { className: "rail__item", type: "button", "aria-current": "page", children: "measures" })] }), _jsxs("main", { className: "bay", children: [_jsx("h1", { className: "bay__title", children: "this machine" }), _jsxs("table", { className: "measures", children: [_jsx("caption", { children: "read through the shared channel" }), _jsx("thead", { children: _jsxs("tr", { children: [_jsx("th", { scope: "col", children: "measure" }), _jsx("th", { scope: "col", children: "value" }), _jsx("th", { scope: "col" })] }) }), _jsx("tbody", { children: rows(reading, previous).map((row) => (_jsx(Row_, { row: row, tolerance: tolerance }, row.label))) })] })] })] }));
}
/**
 * The screen.
 *
 * Holds the previous reading in state rather than in a module, because a module that
 * remembers is state a re-render cannot order and a test cannot set. Keyed on the
 * timestamp so a reading that arrives with the same numbers as the last one does not
 * repaint for nothing.
 */
export function App({ reading }) {
    // Two readings, not one: a trend compares a value against the one before it, and a
    // state that holds only the current reading would compare it against itself — which
    // reports no movement for a value that is climbing, the one error a latency panel
    // cannot afford.
    //
    // Advanced during render rather than in an effect on purpose. An effect runs after the
    // browser has already painted the frame with the stale comparison in it, so the first
    // paint of every reading would show arrows computed from the wrong pair.
    const [current, setCurrent] = useState(reading);
    const [before, setBefore] = useState(null);
    if (reading !== null && reading !== current) {
        setBefore(current);
        setCurrent(reading);
    }
    if (current === null) {
        return _jsx(Waiting, {});
    }
    return _jsx(Measures, { reading: current, previous: before });
}
