// Generated from `measures.ts` by tools/transpile-assets.mjs.
//
// Edit the TypeScript source, not this file: this one is rewritten on every run and
// an edit made here is lost without warning. Running the script in check mode is what
// keeps the two in step.

/**
 * The measures, formatted — and nothing else.
 *
 * ## Why this file exists
 *
 * A screen is a framework's job; the arithmetic is not. `duration`, `bytes`, `trim` and
 * `trend` decide what a number *means* — where the decimal goes, which unit keeps three
 * figures, whether an arrow is honest — and none of that changes when the screen is
 * written in React instead of the DOM. So it lives here, once, and every screen is a view
 * over it.
 *
 * That is not tidiness for its own sake. The first version of this screen had the
 * arithmetic inline, and the moment a second framework was added the numbers would have
 * had two implementations to disagree — and two implementations of "round to three
 * figures" disagree in exactly the cases where nobody looks.
 *
 * ## Why it is pure
 *
 * `rows()` takes the previous reading as an argument instead of remembering it. A module
 * that remembers has state a test cannot set and a re-render cannot order, and a trend
 * arrow computed from the wrong "previous" is a number presented as a movement that did
 * not happen.
 */
/** The half-millisecond a round trip is allowed before it is called out.
 *
 * A round number in every unit a developer might reason in, and roughly four orders of
 * magnitude above the measured p50 — so a project has to be genuinely broken to reach
 * it, not merely busy. It is a fact about this channel, not about how a screen is painted,
 * which is why it is here and not in a stylesheet.
 */
export const TOLERANCE_NS = 500000n;
/** Formats a duration in nanoseconds at the largest unit that keeps it readable. */
export function duration(nanoseconds) {
  const units = [
    [1000000000n, "s"],
    [1000000n, "ms"],
    [1000n, "µs"],
    [1n, "ns"],
  ];
  for (const [scale, suffix] of units) {
    if (nanoseconds >= scale) {
      return `${trim((nanoseconds * 100n) / scale)} ${suffix}`;
    }
  }
  return "0 ns";
}
/** Formats a byte count in the largest binary unit that fits three figures. */
export function bytes(count) {
  const units = [
    [1n << 30n, "GiB"],
    [1n << 20n, "MiB"],
    [1n << 10n, "KiB"],
  ];
  for (const [scale, suffix] of units) {
    if (count >= scale) {
      return `${trim((count * 100n) / scale)} ${suffix}`;
    }
  }
  return `${count} B`;
}
/** Rounds hundredths to at most one decimal place and drops a trailing `.0`. */
function trim(hundredths) {
  // Hundredths: the whole part is a hundredth of it. Dividing by ten instead — as the
  // first version did — showed every figure on the panel ten times too large (a 67 MiB
  // process read "672 MiB"), which is the one kind of wrong a measures screen exists
  // to make impossible.
  const whole = hundredths / 100n;
  // One decimal, truncated rather than rounded: the second is noise, and a latency that
  // reads high is the direction that hides a problem.
  const tenth = (hundredths % 100n) / 10n;
  if (tenth === 0n) {
    return whole.toString();
  }
  return `${whole}.${tenth.toString()}`;
}
/** Which way a value moved, or null when it did not or cannot. */
export function trend(now, before) {
  if (before === undefined) {
    return null;
  }
  if (now > before) {
    return "rising";
  }
  if (now < before) {
    return "falling";
  }
  return null;
}
/** The rows for one reading, in the order the table reads. */
export function rows(reading, previous) {
  return [
    {
      // Named for what it is: `timestamp_ns` is a monotonic clock reading on the core's
      // machine, not the time the machine has been up. Calling it uptime would be a
      // different measurement wearing this one's label.
      label: "core clock",
      value: duration(reading.timestampNs),
      exact: `${reading.timestampNs} ns since boot, monotonic`,
      // Rises by construction, so the direction is asserted rather than observed — a row
      // whose arrow disagrees with its number is a number computed wrong.
      trend: trend(reading.timestampNs, previous?.timestampNs) ?? "rising",
    },
    {
      label: "resident",
      value: bytes(reading.rssBytes),
      exact: `${reading.rssBytes} bytes`,
      trend: trend(reading.rssBytes, previous?.rssBytes),
    },
    {
      label: "ring free",
      value: `${reading.ringFreeCells} / ${reading.ringCapacityCells}`,
      exact: `${reading.ringFreeCells} free of ${reading.ringCapacityCells} cells`,
      trend: null,
    },
    {
      // The only number on this screen that predicts a future problem, so it is the one
      // that carries the tolerance mark.
      label: "round trip p50",
      value: duration(reading.roundTripNs),
      exact: `${reading.roundTripNs} ns`,
      trend: trend(reading.roundTripNs, previous?.roundTripNs),
    },
    {
      label: "round trip max",
      value: duration(reading.roundTripMaxNs),
      exact: `${reading.roundTripMaxNs} ns`,
      trend: trend(reading.roundTripMaxNs, previous?.roundTripMaxNs),
    },
  ];
}
/** Whether a reading is outside the round-trip tolerance. */
export function exceedsTolerance(reading) {
  return reading.roundTripNs > TOLERANCE_NS;
}
