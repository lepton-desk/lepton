//! Named shared-memory regions: the kernel object the channel's rings live in.
//!
//! One interface, two kernels. Linux and the BSDs get POSIX shared memory
//! (`shm_posix.zig`); Windows gets a named section backed by the paging file
//! (`shm_windows.zig`). The names callers pass are the POSIX form — one leading `/`,
//! no other separator — on both, so a channel is named the same way everywhere.
//!
//! The one difference callers can observe is lifetime. A POSIX object outlives the
//! process that made it until someone unlinks it; a Windows section disappears with
//! its last handle, so `unlink` there has nothing to remove and a killed owner leaves
//! nothing behind.

const builtin = @import("builtin");

const impl = if (builtin.os.tag == .windows) @import("shm_windows.zig") else @import("shm_posix.zig");

pub const page_align = impl.page_align;
pub const Error = impl.Error;
pub const Region = impl.Region;
pub const create = impl.create;
pub const attach = impl.attach;
pub const unlink = impl.unlink;

test {
    _ = impl;
}
