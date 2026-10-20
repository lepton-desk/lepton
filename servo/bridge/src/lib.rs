//! Lepton's Servo bridge.
//!
//! Servo behind the C ABI in `zig/servo/lepton_servo.h`, built as `liblepton_servo.so`
//! for the Zig core to link when an app is built with Servo. Servo draws into the core's
//! own window (X11 through Xlib, Wayland through its `wl_surface`), takes the input the
//! core forwards, and hands the page's requests on the app's scheme to the core.

mod abi;
mod engine;
mod request;
mod scheme;
