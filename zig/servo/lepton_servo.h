/*
 * Lepton's Servo bridge: the C ABI between the Zig core and Servo.
 *
 * Servo is a Rust library; the core is Zig. The bridge (`servo/bridge`, built as
 * `liblepton_servo.so`) owns Servo and exposes only what the core's view needs: draw
 * into the core's own window, take its input, and hand the page's requests on the
 * app's scheme to the core, which answers them as it answers WebKit's and WebView2's
 * (`render/webview/bridge.zig`).
 *
 * Threads: every function here is called on the thread that called
 * `lepton_servo_create`, except `wake`, which Servo calls from any thread. The core
 * answers `wake` by calling `lepton_servo_spin` on its own thread; every other
 * callback runs inside `lepton_servo_spin`.
 *
 * Re-entry: a callback calls none of the functions that take the `LeptonServo`
 * (`lepton_servo_load`, `_resize`, `_spin`, `_screenshot`, the input calls, and above all
 * `_destroy`); answering a request from a callback is allowed. The bridge keeps the
 * webview in a `RefCell`, which `lepton_servo_load` holds mutably while it runs, so a
 * call that reaches the webview from inside it panics. Whether Servo runs a delegate
 * synchronously inside `load` is not measured; the callbacks in the core's
 * `servo/view.zig` make no such call themselves.
 *
 * Layout: both sides check these structs' sizes and offsets against the numbers
 * written beside them (Rust in `servo/bridge/src/abi.rs`, Zig where it imports this
 * header). A struct changed on one side only fails a test, not a frame.
 */
#ifndef LEPTON_SERVO_H
#define LEPTON_SERVO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The engine and its one view. One per process: Servo starts once. */
typedef struct LeptonServo LeptonServo;

/* One request from the page to the app's scheme. Counted: the core keeps it with
 * `ref`, drops it with `unref`, and answers it at most once with `respond`. One that
 * was never answered when its last reference goes is answered 500. */
typedef struct LeptonServoRequest LeptonServoRequest;

#define LEPTON_SERVO_X11 1u     /* display: Xlib `Display *`; window: the window id */
#define LEPTON_SERVO_WAYLAND 2u /* display: `wl_display *`; surface: `wl_surface *` */

/* Where Servo draws. Xlib, not XCB, on X11: surfman takes no XCB connection
 * (`Error::Unimplemented`), and an X11 window is the server's, so a second
 * connection may draw into the core's window by its id. 40 bytes. */
typedef struct LeptonServoSurface {
    uint32_t kind;    /* offset 0 */
    uint32_t width;   /* offset 4, physical pixels */
    void *display;    /* offset 8 */
    void *surface;    /* offset 16, Wayland only */
    uint64_t window;  /* offset 24, X11 only */
    uint32_t height;  /* offset 32, physical pixels */
    float scale;      /* offset 36, device pixels per CSS pixel */
} LeptonServoSurface;

/* What the bridge tells the core. Any member may be null. 56 bytes. */
typedef struct LeptonServoCallbacks {
    void *context; /* offset 0, passed back to each callback */
    /* offset 8. Any thread: Servo has work; call `lepton_servo_spin` soon. */
    void (*wake)(void *context);
    /* offset 16. A request to the app's scheme; the request is the core's to `unref`. */
    void (*request)(void *context, LeptonServoRequest *request);
    /* offset 24. The page's title, UTF-8, not terminated; length 0 when it has none. */
    void (*title)(void *context, const uint8_t *utf8, size_t len);
    /* offset 32. A console message: level 0 log, 1 debug, 2 info, 3 warn, 4 error, 5 trace. */
    void (*console)(void *context, uint32_t level, const uint8_t *utf8, size_t len);
    /* offset 40. The page finished loading (`LoadStatus::Complete`). */
    void (*loaded)(void *context);
    /* offset 48. The view's document is about to become `url`: nonzero lets it, zero
     * stops it. Null lets every navigation through. */
    int32_t (*navigation)(void *context, const uint8_t *url, size_t len);
} LeptonServoCallbacks;

/* Starts Servo drawing into `surface` and registers `scheme` (for example "lepton")
 * for the core. Null on failure, with the reason in `error` (terminated, truncated
 * to `error_capacity`). The callbacks are copied. */
LeptonServo *lepton_servo_create(const LeptonServoSurface *surface,
                                 const uint8_t *scheme, size_t scheme_len,
                                 const LeptonServoCallbacks *callbacks,
                                 char *error, size_t error_capacity);
void lepton_servo_destroy(LeptonServo *servo);

/* A script run in every page before the page's own (the core's `__lepton`).
 * 0 on success. Only before the first `lepton_servo_load`. */
int32_t lepton_servo_add_user_script(LeptonServo *servo, const uint8_t *js, size_t len);
/* 0 on success, -1 for a URL Servo cannot parse. */
int32_t lepton_servo_load(LeptonServo *servo, const uint8_t *url, size_t len);

/* Runs Servo's pending work and paints a ready frame. */
void lepton_servo_spin(LeptonServo *servo);
void lepton_servo_resize(LeptonServo *servo, uint32_t width, uint32_t height);

/* Input, in physical pixels relative to the surface. Buttons: 0 primary, 1 middle,
 * 2 secondary, 3 back, 4 forward. */
void lepton_servo_pointer_move(LeptonServo *servo, double x, double y);
void lepton_servo_pointer_leave(LeptonServo *servo);
void lepton_servo_pointer_button(LeptonServo *servo, uint32_t button, int32_t pressed,
                                 double x, double y);
/* Pixel deltas; positive y scrolls the page up, as the DOM's `deltaY` is negative. */
void lepton_servo_wheel(LeptonServo *servo, double dx, double dy, double x, double y);
/* `key` is the DOM `KeyboardEvent.key` ("a", "Enter", "ArrowLeft"), `code` its
 * `KeyboardEvent.code` ("KeyA"); the core maps its keysyms to them. Modifier bits:
 * 1 shift, 2 control, 4 alt, 8 meta. 0, or -1 for a key or code the DOM does not name. */
int32_t lepton_servo_key(LeptonServo *servo, int32_t pressed, const uint8_t *key,
                         size_t key_len, const uint8_t *code, size_t code_len,
                         uint32_t modifiers, int32_t repeat);

/* Writes the next painted frame to a PNG at `path` (a diagnostic). 0 on success. */
int32_t lepton_servo_screenshot(LeptonServo *servo, const uint8_t *path, size_t len);

/* The request's parts. Pointers stay valid until the last `unref`. */
size_t lepton_servo_request_url(const LeptonServoRequest *request, const uint8_t **url);
size_t lepton_servo_request_method(const LeptonServoRequest *request, const uint8_t **method);
size_t lepton_servo_request_body(const LeptonServoRequest *request, const uint8_t **body);
/* Answers the request; everything is copied. A second answer is ignored.
 * `allow_origin` (length 0 for none) names the one origin that may read the answer
 * cross-origin: the dev server's page reading the core's scheme. Never a wildcard. */
void lepton_servo_request_respond(LeptonServoRequest *request, uint16_t status,
                                  const uint8_t *content_type, size_t content_type_len,
                                  const uint8_t *allow_origin, size_t allow_origin_len,
                                  const uint8_t *bytes, size_t len);
void lepton_servo_request_ref(LeptonServoRequest *request);
void lepton_servo_request_unref(LeptonServoRequest *request);

#ifdef __cplusplus
}
#endif

#endif
