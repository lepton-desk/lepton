//! The Wayland client and xdg-shell C declarations, imported once.
//!
//! Every file of the Wayland window imports this rather than its own `@cImport`: two
//! imports of the same headers produce distinct Zig types, and a `wl_surface` from one
//! could not be handed to a function declared by the other.

pub const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-util.h");
    @cInclude("xdg-shell-client-protocol.h");
});
