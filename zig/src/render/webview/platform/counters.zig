//! What the display module did, for the process that loaded it.
//!
//! Shared by both halves of the platform module — the shared library that counts, and the
//! core that reads the count — because a counter block whose two definitions can drift
//! apart is a block that reports plausible nonsense. One declaration, two importers.
//!
//! Published as a data symbol rather than printed, so a check can *assert* on the engine's
//! behaviour. Reading it out of log lines is how a check passes while measuring nothing —
//! and the first version of the display search failed exactly that way more than once.

/// Counters are monotonic and never reset. A reset would make "how many frames since
/// start" ambiguous at the only moment it matters, which is a comparison against zero.
pub const Counters = extern struct {
    /// Views the engine asked this framework's display for.
    views_created: u64,
    /// Times the engine handed over the buffer formats it can render into. This is the
    /// negotiation the whole platform exists to take part in.
    buffers_changed: u64,
    /// Times the engine was given a buffer to render into.
    render_buffer_calls: u64,
    /// Times the engine asked whether the view may be mapped.
    can_be_mapped_asked: u64,
    /// Buffers this framework allocated and handed to the engine.
    buffers_allocated: u64,
    /// Frames read back out of a rendered buffer. Zero for as long as no frame has been
    /// produced, and the number that must stop being zero before this framework claims to
    /// show a web page.
    frames_read_back: u64,
    /// EGL displays handed to the engine. Zero means the engine had no GL context to
    /// render through, which is the difference between "it drew nothing" and "it had
    /// nothing to draw with".
    egl_displays_created: u64,
    /// Times an EGL display could not be produced at all.
    egl_failures: u64,
    /// Repaint ticks delivered by the main loop. Separate from `render_requests` because
    /// a tick that did not reach the engine is a different failure from an engine that
    /// refused.
    ticks: u64,
    /// Render requests this platform made from its repaint loop.
    render_requests: u64,
    /// Render requests the engine refused. Non-zero here means the timing is wrong, not
    /// that the page is unrenderable.
    render_refusals: u64,
    /// Frames that contained at least one non-zero pixel. This is the count that has to
    /// stop being zero before this framework may say it shows a web page.
    frames_with_pixels: u64,
    /// Views the engine offered that no repaint loop could take, because the table was
    /// full. Reported rather than ignored.
    views_without_a_loop: u64,
    /// Non-zero pixels in the last frame read back. A buffer of exactly the right size
    /// containing nothing at all is what an unwritten allocation looks like, so this is
    /// what distinguishes "the page was drawn" from "the engine gave me memory".
    pixels_non_zero: u64,
};

/// The name the module exports the counters under.
pub const symbol_name = "lepton_platform_counters";