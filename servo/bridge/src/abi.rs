//! The C boundary: one function per declaration in `zig/servo/lepton_servo.h`.
//!
//! The crate's only `unsafe`. Every block reads a pointer the header says the core
//! passes valid, or hands the core a pointer it owns until it gives it back; the rest
//! of the bridge (`engine.rs`, `scheme.rs`, `request.rs`) is safe Rust.

#![allow(unsafe_code)]
// The two handles are opaque to C; it never sees their layout.
#![allow(improper_ctypes_definitions)]

use std::ffi::{c_char, c_ulong, c_void};
use std::ptr::NonNull;
use std::rc::Rc;

use dpi::PhysicalSize;
use raw_window_handle::{
    DisplayHandle, RawDisplayHandle, RawWindowHandle, WaylandDisplayHandle, WaylandWindowHandle,
    WindowHandle, XlibDisplayHandle, XlibWindowHandle,
};

use crate::engine::{Engine, Host};
use crate::request::Request;

pub const X11: u32 = 1;
pub const WAYLAND: u32 = 2;

#[repr(C)]
pub struct LeptonServoSurface {
    pub kind: u32,
    pub width: u32,
    pub display: *mut c_void,
    pub surface: *mut c_void,
    pub window: u64,
    pub height: u32,
    pub scale: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct LeptonServoCallbacks {
    pub context: *mut c_void,
    pub wake: Option<extern "C" fn(*mut c_void)>,
    pub request: Option<extern "C" fn(*mut c_void, *mut Request)>,
    pub title: Option<extern "C" fn(*mut c_void, *const u8, usize)>,
    pub console: Option<extern "C" fn(*mut c_void, u32, *const u8, usize)>,
    pub loaded: Option<extern "C" fn(*mut c_void)>,
    pub navigation: Option<extern "C" fn(*mut c_void, *const u8, usize) -> i32>,
}

/// The core's callbacks, called on the core's thread.
struct CallbackHost(LeptonServoCallbacks);

impl Host for CallbackHost {
    fn request(&self, request: Box<Request>) {
        match self.0.request {
            // The core owns it now and gives it back with `lepton_servo_request_unref`.
            Some(call) => call(self.0.context, Box::into_raw(request)),
            // No one to answer: dropping it answers 500.
            None => {
                request.release();
            }
        }
    }

    fn title(&self, title: Option<&str>) {
        if let Some(call) = self.0.title {
            let text = title.unwrap_or("");
            call(self.0.context, text.as_ptr(), text.len());
        }
    }

    fn console(&self, level: u32, message: &str) {
        if let Some(call) = self.0.console {
            call(self.0.context, level, message.as_ptr(), message.len());
        }
    }

    fn loaded(&self) {
        if let Some(call) = self.0.loaded {
            call(self.0.context);
        }
    }

    fn navigation(&self, url: &str) -> bool {
        match self.0.navigation {
            Some(call) => call(self.0.context, url.as_ptr(), url.len()) != 0,
            None => true,
        }
    }
}

/// The core's `wake`, which Servo calls from its own threads.
struct WakeTarget {
    context: *mut c_void,
    wake: Option<extern "C" fn(*mut c_void)>,
}

impl WakeTarget {
    fn call(&self) {
        if let Some(wake) = self.wake {
            wake(self.context);
        }
    }
}

// SAFETY: the header documents `wake` as callable from any thread; the context is
// only passed back to it, never read here.
unsafe impl Send for WakeTarget {}
// SAFETY: as above; `wake` takes no lock of ours and the pointer is never written.
unsafe impl Sync for WakeTarget {}

/// The bytes at `pointer`, or none for a null pointer or a zero length.
///
/// SAFETY (callers): a non-null `pointer` addresses `len` readable bytes that outlive
/// the call, as every pointer-and-length pair in the header does.
unsafe fn bytes<'a>(pointer: *const u8, len: usize) -> &'a [u8] {
    if pointer.is_null() || len == 0 {
        return &[];
    }
    // SAFETY: non-null and `len` bytes long, per the caller's contract.
    unsafe { std::slice::from_raw_parts(pointer, len) }
}

/// UTF-8 text at `pointer`, or none when it is not UTF-8.
///
/// SAFETY (callers): as for [`bytes`].
unsafe fn text<'a>(pointer: *const u8, len: usize) -> Option<&'a str> {
    // SAFETY: forwarded from the caller.
    std::str::from_utf8(unsafe { bytes(pointer, len) }).ok()
}

/// Writes `message` to the core's buffer, truncated and terminated.
fn report(message: &str, error: *mut c_char, capacity: usize) {
    if error.is_null() || capacity == 0 {
        return;
    }
    let len = message.len().min(capacity - 1);
    // SAFETY: the header gives `error` as `capacity` writable bytes; `len + 1 <= capacity`.
    unsafe {
        std::ptr::copy_nonoverlapping(message.as_ptr(), error.cast::<u8>(), len);
        *error.add(len) = 0;
    }
}

/// The engine behind the core's handle.
///
/// SAFETY (callers): `servo` came from `lepton_servo_create` and has not been destroyed,
/// and is used on the thread that created it.
unsafe fn engine<'a>(servo: *mut Engine) -> Option<&'a Engine> {
    // SAFETY: per the caller's contract.
    unsafe { servo.as_ref() }
}

/// SAFETY (callers): `request` came from the `request` callback and still has a reference.
unsafe fn request<'a>(request: *const Request) -> Option<&'a Request> {
    // SAFETY: per the caller's contract.
    unsafe { request.as_ref() }
}

fn create(
    surface: &LeptonServoSurface,
    scheme: &str,
    callbacks: LeptonServoCallbacks,
) -> Result<Engine, String> {
    let (display, window) = match surface.kind {
        X11 => (
            RawDisplayHandle::Xlib(XlibDisplayHandle::new(NonNull::new(surface.display), 0)),
            RawWindowHandle::Xlib(XlibWindowHandle::new(surface.window as c_ulong)),
        ),
        WAYLAND => {
            let display = NonNull::new(surface.display).ok_or("no wl_display")?;
            let window = NonNull::new(surface.surface).ok_or("no wl_surface")?;
            (
                RawDisplayHandle::Wayland(WaylandDisplayHandle::new(display)),
                RawWindowHandle::Wayland(WaylandWindowHandle::new(window)),
            )
        }
        other => {
            return Err(format!(
                "surface kind {other} is neither X11 (1) nor Wayland (2)"
            ));
        }
    };
    // SAFETY: the core passes its open display connection and a window on it, which
    // stay open until `lepton_servo_destroy`.
    let display = unsafe { DisplayHandle::borrow_raw(display) };
    // SAFETY: as above.
    let window = unsafe { WindowHandle::borrow_raw(window) };
    let target = WakeTarget {
        context: callbacks.context,
        wake: callbacks.wake,
    };
    Engine::create(
        display,
        window,
        PhysicalSize {
            width: surface.width,
            height: surface.height,
        },
        surface.scale,
        scheme,
        Rc::new(CallbackHost(callbacks)),
        // A method call, so the closure captures the whole `WakeTarget` (Send + Sync)
        // rather than its raw-pointer field alone, which edition 2021's per-field
        // capture would take and which is neither.
        Box::new(move || target.call()),
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_set_data_directory(path: *const u8, len: usize) -> i32 {
    // SAFETY: a pointer-and-length pair from the core.
    match unsafe { text(path, len) } {
        Some(path) if !path.is_empty() => {
            crate::engine::set_data_directory(std::path::PathBuf::from(path));
            0
        }
        _ => -1,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_create(
    surface: *const LeptonServoSurface,
    scheme: *const u8,
    scheme_len: usize,
    callbacks: *const LeptonServoCallbacks,
    error: *mut c_char,
    error_capacity: usize,
) -> *mut Engine {
    // SAFETY: the header gives both as valid for the call, or null.
    let (surface, callbacks) = match unsafe { (surface.as_ref(), callbacks.as_ref()) } {
        (Some(surface), Some(callbacks)) => (surface, *callbacks),
        _ => {
            report("no surface or no callbacks", error, error_capacity);
            return std::ptr::null_mut();
        }
    };
    // SAFETY: a pointer-and-length pair from the core.
    let Some(scheme) = (unsafe { text(scheme, scheme_len) }).filter(|s| !s.is_empty()) else {
        report("the scheme is empty or not UTF-8", error, error_capacity);
        return std::ptr::null_mut();
    };
    match create(surface, scheme, callbacks) {
        Ok(engine) => Box::into_raw(Box::new(engine)),
        Err(reason) => {
            report(&reason, error, error_capacity);
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_destroy(servo: *mut Engine) {
    if !servo.is_null() {
        // SAFETY: from `lepton_servo_create`, given back once.
        drop(unsafe { Box::from_raw(servo) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_add_user_script(
    servo: *mut Engine,
    js: *const u8,
    len: usize,
) -> i32 {
    // SAFETY: the core's handle and a pointer-and-length pair.
    match unsafe { (engine(servo), text(js, len)) } {
        (Some(engine), Some(js)) => {
            engine.add_user_script(js);
            0
        }
        _ => -1,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_load(servo: *mut Engine, url: *const u8, len: usize) -> i32 {
    // SAFETY: the core's handle and a pointer-and-length pair.
    match unsafe { (engine(servo), text(url, len)) } {
        (Some(engine), Some(url)) => match engine.load(url) {
            Ok(()) => 0,
            Err(_) => -1,
        },
        _ => -1,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_spin(servo: *mut Engine) {
    // SAFETY: the core's handle.
    if let Some(engine) = unsafe { engine(servo) } {
        engine.spin();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_resize(servo: *mut Engine, width: u32, height: u32) {
    // SAFETY: the core's handle.
    if let Some(engine) = unsafe { engine(servo) } {
        engine.resize(width, height);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_pointer_move(servo: *mut Engine, x: f64, y: f64) {
    // SAFETY: the core's handle.
    if let Some(engine) = unsafe { engine(servo) } {
        engine.pointer_move(x, y);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_pointer_leave(servo: *mut Engine) {
    // SAFETY: the core's handle.
    if let Some(engine) = unsafe { engine(servo) } {
        engine.pointer_leave();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_pointer_button(
    servo: *mut Engine,
    button: u32,
    pressed: i32,
    x: f64,
    y: f64,
) {
    // SAFETY: the core's handle.
    if let Some(engine) = unsafe { engine(servo) } {
        engine.pointer_button(button, pressed != 0, x, y);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_wheel(servo: *mut Engine, dx: f64, dy: f64, x: f64, y: f64) {
    // SAFETY: the core's handle.
    if let Some(engine) = unsafe { engine(servo) } {
        engine.wheel(dx, dy, x, y);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_key(
    servo: *mut Engine,
    pressed: i32,
    key: *const u8,
    key_len: usize,
    code: *const u8,
    code_len: usize,
    modifiers: u32,
    repeat: i32,
) -> i32 {
    // SAFETY: the core's handle and two pointer-and-length pairs.
    match unsafe { (engine(servo), text(key, key_len), text(code, code_len)) } {
        (Some(engine), Some(key), Some(code)) => {
            match engine.key(pressed != 0, key, code, modifiers, repeat != 0) {
                Ok(()) => 0,
                Err(_) => -1,
            }
        }
        _ => -1,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_screenshot(servo: *mut Engine, path: *const u8, len: usize) -> i32 {
    // SAFETY: the core's handle and a pointer-and-length pair.
    match unsafe { (engine(servo), text(path, len)) } {
        (Some(engine), Some(path)) => match engine.screenshot(path.to_owned()) {
            Ok(()) => 0,
            Err(_) => -1,
        },
        _ => -1,
    }
}

/// Points `out` at `value`'s bytes and returns their length.
fn expose(value: &[u8], out: *mut *const u8) -> usize {
    if !out.is_null() {
        // SAFETY: the header gives `out` as one writable pointer.
        unsafe { *out = value.as_ptr() };
    }
    value.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_request_url(request_: *const Request, url: *mut *const u8) -> usize {
    // SAFETY: a request the core holds.
    unsafe { request(request_) }.map_or(0, |r| expose(r.url.as_bytes(), url))
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_request_method(
    request_: *const Request,
    method: *mut *const u8,
) -> usize {
    // SAFETY: a request the core holds.
    unsafe { request(request_) }.map_or(0, |r| expose(r.method.as_bytes(), method))
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_request_body(
    request_: *const Request,
    body: *mut *const u8,
) -> usize {
    // SAFETY: a request the core holds.
    unsafe { request(request_) }.map_or(0, |r| expose(&r.body, body))
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_request_respond(
    request_: *mut Request,
    status: u16,
    content_type: *const u8,
    content_type_len: usize,
    allow_origin: *const u8,
    allow_origin_len: usize,
    bytes_: *const u8,
    len: usize,
) {
    // SAFETY: a request the core holds, and three pointer-and-length pairs.
    let (held, kind, origin, body) = unsafe {
        (
            request(request_),
            text(content_type, content_type_len).unwrap_or("application/octet-stream"),
            text(allow_origin, allow_origin_len).unwrap_or(""),
            bytes(bytes_, len),
        )
    };
    if let Some(held) = held {
        held.respond(status, kind, origin, body);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_request_ref(request_: *mut Request) {
    // SAFETY: a request the core holds.
    if let Some(held) = unsafe { request(request_) } {
        held.reference();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lepton_servo_request_unref(request_: *mut Request) {
    // SAFETY: a request the core holds.
    let last = unsafe { request(request_) }.is_some_and(Request::release);
    if last {
        // SAFETY: the last reference: made by `Box::into_raw` in `CallbackHost::request`.
        drop(unsafe { Box::from_raw(request_) });
    }
}

#[cfg(test)]
mod tests {
    use super::{LeptonServoCallbacks, LeptonServoSurface};
    use std::mem::{offset_of, size_of};

    /// The numbers written beside each member in `zig/servo/lepton_servo.h`.
    #[test]
    fn the_structs_match_the_header() {
        assert_eq!(size_of::<LeptonServoSurface>(), 40);
        assert_eq!(offset_of!(LeptonServoSurface, kind), 0);
        assert_eq!(offset_of!(LeptonServoSurface, width), 4);
        assert_eq!(offset_of!(LeptonServoSurface, display), 8);
        assert_eq!(offset_of!(LeptonServoSurface, surface), 16);
        assert_eq!(offset_of!(LeptonServoSurface, window), 24);
        assert_eq!(offset_of!(LeptonServoSurface, height), 32);
        assert_eq!(offset_of!(LeptonServoSurface, scale), 36);

        assert_eq!(size_of::<LeptonServoCallbacks>(), 56);
        assert_eq!(offset_of!(LeptonServoCallbacks, context), 0);
        assert_eq!(offset_of!(LeptonServoCallbacks, wake), 8);
        assert_eq!(offset_of!(LeptonServoCallbacks, request), 16);
        assert_eq!(offset_of!(LeptonServoCallbacks, title), 24);
        assert_eq!(offset_of!(LeptonServoCallbacks, console), 32);
        assert_eq!(offset_of!(LeptonServoCallbacks, loaded), 40);
        assert_eq!(offset_of!(LeptonServoCallbacks, navigation), 48);
    }
}
