/**
 * The binding between the frontend and the Zig core.
 *
 * ## What this is
 *
 * A typed view over the bytes the core already published into shared memory. A
 * `MeasureSet` is not parsed out of the mapping and it is not copied out of it: the
 * getters below read a fixed-width field straight from the mapped bytes with one
 * load, which is the entire reason the frame format is fixed-width in the first
 * place. Nothing here allocates per field, so the cost of showing a reading is the
 * cost of showing it, not the cost of the bridge.
 *
 * ## The layout is a contract, not an implementation detail
 *
 * Every offset below has a named counterpart in `zig/src/ipc/wire.zig`. Change one
 * and the other breaks silently — a reader that reads `rss_bytes` at the wrong
 * offset gets a plausible number — so the two files are named in comments at each
 * offset rather than at the top of the file where it would be read once.
 *
 * ## What the native side owes this module
 *
 * Exactly one thing, and it is narrow on purpose: the mapped region's bytes and the
 * sequence number of the newest frame in it. Everything else — decoding, tracking,
 * notification — happens here, where it can be read.
 */

/**
 * Where everything sits in the core's outbound ring, in bytes.
 *
 * Supplied by the transport, never written down here. The core derives every number
 * from the `extern struct`s it writes (`ring.Header`, `ring.CellHeader`, `wire.Header`,
 * `wire.Sample`) when it builds the page's transport, so this module cannot read a
 * layout the core does not write. The first version of this file guessed one — cell
 * count at offset 0, cells from the region's first byte — and could never have found
 * a frame in a real ring.
 */
export interface ChannelLayout {
  readonly headerBytes: number;
  readonly cellCountOffset: number;
  readonly cellStrideOffset: number;
  readonly enqueueOffset: number;
  readonly cellHeaderBytes: number;
  readonly cellSeqOffset: number;
  readonly cellLenOffset: number;
  readonly wireHeaderBytes: number;
  readonly wireProtocolOffset: number;
  readonly wireKindOffset: number;
  readonly protocol: number;
  readonly kindSample: number;
  readonly sample: {
    readonly timestampNs: number;
    readonly rssBytes: number;
    readonly heapHighWaterBytes: number;
    readonly heapInUseBytes: number;
    readonly ringFreeCells: number;
    readonly ringCapacityCells: number;
    readonly roundTripNs: number;
    readonly roundTripMaxNs: number;
  };
}

/** One reading of this machine, published by the core.
 *
 * Every field is a `bigint` because the underlying values are `u64`. A number would
 * lose precision above 2^53 — which is about 104 days of nanosecond uptime, so not
 * a theoretical concern for a long-running desktop application.
 */
export interface MeasureSet {
  /** Monotonic clock reading on the core's machine, in nanoseconds. */
  readonly timestampNs: bigint;
  /** Resident set size of the core process, in bytes. */
  readonly rssBytes: bigint;
  /** Peak heap the core's allocator has handed out, in bytes. */
  readonly heapHighWaterBytes: bigint;
  /** Bytes the core's allocator currently holds, in bytes. */
  readonly heapInUseBytes: bigint;
  /** Free cells in the shared ring when the reading was taken. */
  readonly ringFreeCells: number;
  /** Total cells in the shared ring. */
  readonly ringCapacityCells: number;
  /** Round trip of the previous request and reply, in nanoseconds. */
  readonly roundTripNs: bigint;
  /** Worst round trip since the core started, in nanoseconds. */
  readonly roundTripMaxNs: bigint;
}

/** What the native side hands over.
 *
 * The whole of the framework's native obligation, expressed as one interface. A
 * future implementation — a Servo binding, a WebView2 bridge, a native render path
 * with no webview at all — satisfies this and nothing else, which is what makes the
 * three render paths share one frontend instead of three frontends.
 */
export interface ChannelTransport {
  /** Byte offsets of the ring `bytes` holds, as the core lays it out. */
  readonly layout: ChannelLayout;

  /**
   * The core's outbound ring: its header and every cell.
   *
   * One array for the page's lifetime, refreshed in place. In a webview it is a
   * snapshot of the mapping (a page cannot map another process's memory), copied once
   * by the engine; a transport that can map the region hands over the mapping itself.
   */
  readonly bytes: Uint8Array;

  /** The ring's enqueue position: how many frames the core has ever published. */
  newestSequence(): bigint;

  /** Called when the core publishes a new frame. Returns a function to unsubscribe. */
  onPublished(listener: (sequence: bigint) => void): () => void;

  /** Whether the core is still on the other end. */
  isConnected(): boolean;

  /** Tells the core the window is closing, so it can tear its side down in order. */
  close(): Promise<void>;
}

/**
 * The transport this build of the frontend is bound to.
 *
 * Read from the global the native side installs, and resolved once at module load:
 * a transport that could change mid-session would mean a reading could be taken
 * from one mapping and compared against another's sequence, which is the one class
 * of bug a zero-copy reader cannot detect on its own.
 *
 * A missing global is the one failure that cannot be handled here, and it is not
 * papered over: there is no fallback, because a fallback would be fabricated
 * numbers on a screen whose whole claim is that they are measured.
 */
function resolveTransport(): ChannelTransport {
  const installed = (globalThis as { __lepton?: ChannelTransport }).__lepton;

  if (installed === undefined) {
    throw new Error(
      "lepton: the native channel is not attached. This file is running outside a Lepton window, where there is no core to read from.",
    );
  }

  return installed;
}

const transport = resolveTransport();
const layout = transport.layout;

/** A view over the mapping, typed once. */
const view = new DataView(
  transport.bytes.buffer,
  transport.bytes.byteOffset,
  transport.bytes.byteLength,
);

/**
 * Reads one `MeasureSet` from the frame at `sequence`'s slot.
 *
 * Zero-copy in the sense that matters: the returned object holds eight numbers read
 * once, and the mapping is not touched again. It is not a view over live bytes,
 * because a live view would let the core overwrite a number between the moment a
 * developer read the label and the moment they read the value.
 */
function readSample(payloadOffset: number): MeasureSet {
  const at = layout.sample;
  return {
    timestampNs: view.getBigUint64(payloadOffset + at.timestampNs, true),
    rssBytes: view.getBigUint64(payloadOffset + at.rssBytes, true),
    heapHighWaterBytes: view.getBigUint64(payloadOffset + at.heapHighWaterBytes, true),
    heapInUseBytes: view.getBigUint64(payloadOffset + at.heapInUseBytes, true),
    ringFreeCells: view.getUint32(payloadOffset + at.ringFreeCells, true),
    ringCapacityCells: view.getUint32(payloadOffset + at.ringCapacityCells, true),
    roundTripNs: view.getBigUint64(payloadOffset + at.roundTripNs, true),
    roundTripMaxNs: view.getBigUint64(payloadOffset + at.roundTripMaxNs, true),
  };
}

/**
 * The newest reading, or null when there is not one yet.
 *
 * Null rather than zeroes: a core that has published nothing has measured nothing,
 * and a screen that showed zero for every field would be showing a measurement that
 * does not exist.
 *
 * The ring is a Vyukov queue: position `p` lives in cell `p mod count`, and that cell
 * is published while its own sequence reads `p + 1`. Walking back from the enqueue
 * position finds the newest published sample; a cell the core is rewriting, or one
 * from an earlier lap, fails that check and is skipped rather than misread.
 */
function latestSample(): MeasureSet | null {
  const position = transport.newestSequence();
  if (position === 0n) {
    return null;
  }

  const count = view.getUint32(layout.cellCountOffset, true);
  const stride = view.getUint32(layout.cellStrideOffset, true);
  if (count === 0 || stride === 0) {
    return null;
  }

  const span = BigInt(count);
  for (let back = 1n; back <= span && back <= position; back += 1n) {
    const at = position - back;
    const cell = layout.headerBytes + Number(at % span) * stride;
    if (view.getBigUint64(cell + layout.cellSeqOffset, true) !== at + 1n) {
      continue;
    }
    const frame = cell + layout.cellHeaderBytes;
    // Checked rather than assumed: a frame of another kind, or from a core speaking
    // another protocol, is not read as a sample.
    if (view.getUint16(frame + layout.wireProtocolOffset, true) !== layout.protocol) {
      continue;
    }
    if (view.getUint16(frame + layout.wireKindOffset, true) !== layout.kindSample) {
      continue;
    }
    return readSample(frame + layout.wireHeaderBytes);
  }
  return null;
}

/**
 * A reading and whether a core is behind it.
 *
 * One type rather than two arguments because the two are never separately useful:
 * a reading with no core behind it is stale, and presenting stale as current is the
 * single mistake this module exists to prevent. A caller that wants to show a number
 * has to have decided what to do about a `null`.
 */
export interface Reading {
  /** The newest reading, or null when the core has published none yet. */
  readonly measures: MeasureSet | null;
  /** Whether a core is attached and has published something. */
  readonly connected: boolean;
}

/** The channel, as the frontend sees it. */
export const channel = {
  /**
   * The newest reading, and whether there is a core attached.
   *
   * Both together because a screen needs them in the same breath: a reading with no
   * core behind it is stale, and showing it as current is the one mistake this
   * module exists to prevent.
   */
  latest(): Reading {
    const sample = latestSample();
    return {
      // Null rather than zeroes: a core that has published nothing has measured
      // nothing, and a zero would be a measurement that does not exist.
      measures: sample,
      connected: transport.isConnected() && sample !== null,
    };
  },

  isConnected(): boolean {
    return transport.isConnected();
  },

  close(): Promise<void> {
    return transport.close();
  },
};

/** Readings, as they arrive. */
export const measures = {
  subscribe(listener: (reading: MeasureSet) => void): () => void {
    // One subscription to the core, however many listeners there are. The core
    // publishes at its own rate; a fan-out that asked it once per listener would
    // make the frame rate a function of the subscriber count.
    const active = new Set<(reading: MeasureSet) => void>();
    let unsubscribe: (() => void) | null = null;

    const start = (): void => {
      if (unsubscribe !== null) {
        return;
      }
      unsubscribe = transport.onPublished(() => {
        const sample = latestSample();
        if (sample !== null) {
          for (const one of active) {
            one(sample);
          }
        }
      });
    };

    const stop = (): void => {
      if (active.size === 0 && unsubscribe !== null) {
        unsubscribe();
        unsubscribe = null;
      }
    };

    const wrapped = (reading: MeasureSet): void => {
      listener(reading);
    };

    active.add(wrapped);
    start();

    return () => {
      active.delete(wrapped);
      stop();
    };
  },
};
