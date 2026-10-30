//! Servo and its one view, driven from the core's thread.
//!
//! Safe Rust only: everything that touches a C pointer is in `abi.rs`, which turns the
//! core's handles into `raw-window-handle` values and its callbacks into a [`Host`].

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;
use std::str::FromStr;
use std::sync::{Arc, Mutex};

use dpi::PhysicalSize;
use euclid::Scale;
use keyboard_types::{Code, Key, KeyState, Location, Modifiers};
use raw_window_handle::{DisplayHandle, WindowHandle};
use servo::protocol_handler::ProtocolRegistry;
use servo::{
    ConsoleLogLevel, ContextMenu, ContextMenuAction, ContextMenuElementInformationFlags, Cursor,
    DevicePoint, EmbedderControl, EmbedderControlId, EventLoopWaker, InputEvent, JSValue,
    KeyboardEvent, LoadStatus, MouseButton, MouseButtonAction, MouseButtonEvent,
    MouseLeftViewportEvent, MouseMoveEvent, NavigationRequest, Opts, Preferences, RenderingContext,
    Servo, ServoBuilder, UserContentManager, UserScript, WebView, WebViewBuilder, WebViewDelegate,
    WheelDelta, WheelEvent, WheelMode, WindowRenderingContext,
};
use url::Url;

use crate::request::Request;
use crate::scheme::{Queue, Scheme};

/// What the engine tells the core, on the core's thread.
pub trait Host {
    fn request(&self, request: Box<Request>);
    fn title(&self, title: Option<&str>);
    fn console(&self, level: u32, message: &str);
    fn loaded(&self);
    /// Whether the view's document may become `url`.
    fn navigation(&self, url: &str) -> bool;
    /// The page's cursor, by its CSS name (`pointer`, `text`, `e-resize`…), which is also
    /// the name the freedesktop cursor themes give it.
    fn cursor(&self, name: &str);
    /// A right click the page did not take: the core shows its menu and answers with
    /// `Engine::context_menu_select`. `editable`: a text field; `selection`: text is
    /// selected there, or in the page.
    /// `false`: nothing is shown, and Servo is told so.
    fn context_menu(&self, editable: bool, selection: bool) -> bool;
}

/// Where Servo keeps the application's web data, set before the engine starts.
static DATA_DIRECTORY: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Names the directory for cookies, storage and caches (`lepton_servo_set_data_directory`).
pub fn set_data_directory(directory: PathBuf) {
    if let Ok(mut guard) = DATA_DIRECTORY.lock() {
        *guard = Some(directory);
    }
}

/// Servo's wake-up, from any thread, forwarded to the core through the queue's waker.
#[derive(Clone)]
struct Waker(Arc<Queue>);

impl EventLoopWaker for Waker {
    fn clone_box(&self) -> Box<dyn EventLoopWaker> {
        Box::new(self.clone())
    }

    fn wake(&self) {
        self.0.wake();
    }
}

struct Page {
    host: Rc<dyn Host>,
    /// A frame is ready and not yet painted.
    dirty: Cell<bool>,
    /// Servo's context menu while the core's is open, and whether it was opened over a
    /// text field. Dropped unanswered, it tells Servo nothing was chosen.
    menu: Rc<RefCell<Option<(ContextMenu, bool)>>>,
}

impl WebViewDelegate for Page {
    fn notify_new_frame_ready(&self, _webview: WebView) {
        self.dirty.set(true);
    }

    fn notify_page_title_changed(&self, _webview: WebView, title: Option<String>) {
        self.host.title(title.as_deref());
    }

    fn notify_cursor_changed(&self, _webview: WebView, cursor: Cursor) {
        self.host.cursor(css_cursor(cursor));
    }

    /// Every navigation asks the core first: a page that sent the window to the web would
    /// otherwise show it inside the application (audit, 2026-10-20). Servo asks for inner
    /// frames too and does not say which is which (`NavigationRequest` keeps its pipeline
    /// private), so on Servo an embedded frame of another site is refused as well.
    fn request_navigation(&self, _webview: WebView, navigation_request: NavigationRequest) {
        if self.host.navigation(navigation_request.url.as_str()) {
            navigation_request.allow();
        } else {
            navigation_request.deny();
        }
    }

    fn notify_load_status_changed(&self, _webview: WebView, status: LoadStatus) {
        if status == LoadStatus::Complete {
            self.host.loaded();
        }
    }

    /// Servo's context menu, asked for only when the page did not cancel `contextmenu`.
    /// Its own items are a browser's (Back, Reload, links); the core shows Lepton's
    /// editing menu instead (`render/webview/context_menu.zig`). Servo reports a selection
    /// only inside a text field, so the page's own is read from the page.
    fn show_embedder_control(&self, webview: WebView, embedder_control: EmbedderControl) {
        let EmbedderControl::ContextMenu(menu) = embedder_control else {
            return;
        };
        let flags = menu.element_info().flags;
        let editable = flags.contains(ContextMenuElementInformationFlags::EditableText);
        let selection = flags.contains(ContextMenuElementInformationFlags::Selection);
        *self.menu.borrow_mut() = Some((menu, editable));
        if editable {
            if !self.host.context_menu(true, selection) {
                dismiss(&self.menu);
            }
            return;
        }
        let host = Rc::clone(&self.host);
        let open = Rc::clone(&self.menu);
        webview.evaluate_javascript(
            "String(globalThis.getSelection()).length > 0",
            move |result| {
                let selected = matches!(result, Ok(JSValue::Boolean(true)));
                if !host.context_menu(false, selected) {
                    dismiss(&open);
                }
            },
        );
    }

    fn hide_embedder_control(&self, _webview: WebView, control_id: EmbedderControlId) {
        let mut menu = self.menu.borrow_mut();
        if menu
            .as_ref()
            .is_some_and(|(open, _)| open.id() == control_id)
        {
            *menu = None;
        }
    }

    fn show_console_message(&self, _webview: WebView, level: ConsoleLogLevel, message: String) {
        let level = match level {
            ConsoleLogLevel::Log | ConsoleLogLevel::Dir => 0,
            ConsoleLogLevel::Debug => 1,
            ConsoleLogLevel::Info => 2,
            ConsoleLogLevel::Warn => 3,
            ConsoleLogLevel::Error => 4,
            ConsoleLogLevel::Trace => 5,
        };
        self.host.console(level, &message);
    }
}

/// Tells Servo the open context menu chose nothing.
fn dismiss(menu: &RefCell<Option<(ContextMenu, bool)>>) {
    if let Some((open, _)) = menu.borrow_mut().take() {
        open.dismiss();
    }
}

pub struct Engine {
    servo: Servo,
    context: Rc<WindowRenderingContext>,
    queue: Arc<Queue>,
    page: Rc<Page>,
    scripts: Rc<UserContentManager>,
    scale: f32,
    webview: RefCell<Option<WebView>>,
}

/// Mouse buttons in the header's numbering.
fn button(number: u32) -> MouseButton {
    match number {
        0 => MouseButton::Primary,
        1 => MouseButton::Auxiliary,
        2 => MouseButton::Secondary,
        3 => MouseButton::Back,
        4 => MouseButton::Forward,
        other => MouseButton::Other(u16::try_from(other).unwrap_or(u16::MAX)),
    }
}

/// Modifier bits in the header's numbering: 1 shift, 2 control, 4 alt, 8 meta.
fn modifiers(bits: u32) -> Modifiers {
    let mut modifiers = Modifiers::empty();
    for (bit, modifier) in [
        (1, Modifiers::SHIFT),
        (2, Modifiers::CONTROL),
        (4, Modifiers::ALT),
        (8, Modifiers::META),
    ] {
        if bits & bit != 0 {
            modifiers |= modifier;
        }
    }
    modifiers
}

fn point(x: f64, y: f64) -> servo::WebViewPoint {
    DevicePoint::new(x as f32, y as f32).into()
}

impl Engine {
    /// Starts Servo drawing into the core's window, with `scheme` answered by the core.
    pub fn create(
        display: DisplayHandle<'_>,
        window: WindowHandle<'_>,
        size: PhysicalSize<u32>,
        scale: f32,
        scheme: &str,
        host: Rc<dyn Host>,
        wake: Box<dyn Fn() + Send + Sync>,
    ) -> Result<Self, String> {
        let context = Rc::new(
            WindowRenderingContext::new(display, window, size)
                .map_err(|error| format!("the window's rendering context: {error:?}"))?,
        );
        context
            .make_current()
            .map_err(|error| format!("make the rendering context current: {error:?}"))?;

        // Before anything computes an origin: the app's pages get a tuple origin, so they
        // have storage (`servo/patches/servo-url`).
        servo_url::register_tuple_origin_scheme(scheme);
        let queue = Arc::new(Queue::new(wake));
        let mut protocols = ProtocolRegistry::default();
        protocols
            .register(
                scheme,
                Scheme {
                    queue: Arc::clone(&queue),
                },
            )
            .map_err(|error| format!("register the {scheme} scheme: {error:?}"))?;
        // Cookies, `localStorage`, IndexedDB and the HTTP cache in the application's own
        // directory (`set_data_directory`); without one Servo keeps them in memory only, so
        // nothing lasts past the run and nothing is shared with another application.
        let data_directory = DATA_DIRECTORY
            .lock()
            .map(|guard| guard.clone())
            .unwrap_or(None);
        let opts = Opts {
            temporary_storage: data_directory.is_none(),
            config_dir: data_directory,
            ..Opts::default()
        };
        // WebGL 2, which Servo 0.6 ships switched off (`dom_webgl2_enabled`). Without it a 3D
        // engine falls back to WebGL 1 and its slower paths: measured with Babylon.js, the main
        // pass took 2-2.5x as long as in Chromium, one `uniformMatrix4fv` per matrix where
        // WebGL 2 uploads a uniform buffer.
        let preferences = Preferences {
            dom_webgl2_enabled: true,
            ..Preferences::default()
        };
        let servo = ServoBuilder::default()
            .opts(opts)
            .preferences(preferences)
            .protocol_registry(protocols)
            .event_loop_waker(Box::new(Waker(Arc::clone(&queue))))
            .build();
        // Servo's own log, to stderr, only when asked for: `RUST_LOG=warn` and so on. Set
        // once per process (a second logger would be refused), and Servo starts once.
        if std::env::var_os("RUST_LOG").is_some() {
            servo.setup_logging();
        }
        let scripts = Rc::new(UserContentManager::new(&servo));
        Ok(Self {
            servo,
            context,
            queue,
            page: Rc::new(Page {
                host,
                dirty: Cell::new(false),
                menu: Rc::new(RefCell::new(None)),
            }),
            scripts,
            scale: if scale > 0.0 { scale } else { 1.0 },
            webview: RefCell::new(None),
        })
    }

    /// The core's answer to [`Host::context_menu`]: 1 cut, 2 copy, 3 paste, 4 select all,
    /// anything else nothing. Servo performs its editing actions only inside a text field;
    /// outside one, Select All is the page's own selection API.
    pub fn context_menu_select(&self, action: u32) {
        let Some((menu, editable)) = self.page.menu.borrow_mut().take() else {
            return;
        };
        match action {
            1 => menu.select(ContextMenuAction::Cut),
            2 => menu.select(ContextMenuAction::Copy),
            3 => menu.select(ContextMenuAction::Paste),
            4 if editable => menu.select(ContextMenuAction::SelectAll),
            4 => {
                menu.dismiss();
                if let Some(view) = self.webview.borrow().as_ref() {
                    view.evaluate_javascript(
                        "globalThis.getSelection().selectAllChildren(document.body)",
                        |_| {},
                    );
                }
            }
            _ => menu.dismiss(),
        }
    }

    pub fn add_user_script(&self, js: &str) {
        self.scripts
            .add_script(Rc::new(UserScript::new(js.to_owned(), None)));
    }

    pub fn load(&self, address: &str) -> Result<(), String> {
        let url = Url::parse(address).map_err(|error| format!("{address}: {error}"))?;
        let mut webview = self.webview.borrow_mut();
        match webview.as_ref() {
            Some(view) => view.load(url),
            None => {
                *webview = Some(
                    WebViewBuilder::new(&self.servo, self.context.clone())
                        .delegate(self.page.clone())
                        .user_content_manager(Rc::clone(&self.scripts))
                        .hidpi_scale_factor(Scale::new(self.scale))
                        .url(url)
                        .build(),
                );
            }
        }
        Ok(())
    }

    /// Servo's pending work, the core's pending requests, and a ready frame.
    pub fn spin(&self) {
        self.servo.spin_event_loop();
        for pending in self.queue.take() {
            self.page.host.request(Box::new(Request::new(pending)));
        }
        if self.page.dirty.replace(false) {
            if let Some(view) = self.webview.borrow().as_ref() {
                view.paint();
                self.context.present();
            }
        }
    }

    fn input(&self, event: InputEvent) {
        if let Some(view) = self.webview.borrow().as_ref() {
            view.notify_input_event(event);
        }
    }

    /// Resizes the view, or before the first `load` the rendering context it will get: the
    /// template sizes the window before it loads, and that size was dropped, leaving Servo
    /// drawing 800×600 in a 1200×800 window (measured in CI, 2026-10-20).
    /// Servo's cookie jar to the data directory, and its network stopped
    /// (`servo/patches/servo`, `write_network_state_and_stop`): Servo writes the jar only
    /// at the end of its own shutdown, which the core never waits for (`_exit`).
    pub fn write_state(&self) {
        self.servo
            .site_data_manager()
            .write_network_state_and_stop();
    }

    pub fn resize(&self, width: u32, height: u32) {
        let size = PhysicalSize {
            width: width.max(1),
            height: height.max(1),
        };
        match self.webview.borrow().as_ref() {
            Some(view) => view.resize(size),
            None => self.context.resize(size),
        }
    }

    pub fn pointer_move(&self, x: f64, y: f64) {
        self.input(InputEvent::MouseMove(MouseMoveEvent::new(point(x, y))));
    }

    pub fn pointer_leave(&self) {
        self.input(InputEvent::MouseLeftViewport(MouseLeftViewportEvent {
            focus_moving_to_another_iframe: false,
        }));
    }

    pub fn pointer_button(&self, number: u32, pressed: bool, x: f64, y: f64) {
        let action = if pressed {
            MouseButtonAction::Down
        } else {
            MouseButtonAction::Up
        };
        self.input(InputEvent::MouseButton(MouseButtonEvent::new(
            action,
            button(number),
            point(x, y),
        )));
    }

    pub fn wheel(&self, dx: f64, dy: f64, x: f64, y: f64) {
        self.input(InputEvent::Wheel(WheelEvent::new(
            WheelDelta {
                x: dx,
                y: dy,
                z: 0.0,
                mode: WheelMode::DeltaPixel,
            },
            point(x, y),
        )));
    }

    /// A key, by its DOM `key` and `code`. Err for names the DOM does not have.
    pub fn key(
        &self,
        pressed: bool,
        key: &str,
        code: &str,
        modifier_bits: u32,
        repeat: bool,
    ) -> Result<(), String> {
        let key = Key::from_str(key).map_err(|_| format!("no DOM key named {key:?}"))?;
        let code = Code::from_str(code).map_err(|_| format!("no DOM code named {code:?}"))?;
        self.input(InputEvent::Keyboard(KeyboardEvent::new(
            keyboard_types::KeyboardEvent {
                state: if pressed {
                    KeyState::Down
                } else {
                    KeyState::Up
                },
                key,
                code,
                location: Location::Standard,
                modifiers: modifiers(modifier_bits),
                repeat,
                is_composing: false,
            },
        )));
        Ok(())
    }

    /// Saves the next painted frame as a PNG; the outcome arrives as a console message.
    pub fn screenshot(&self, path: String) -> Result<(), String> {
        let webview = self.webview.borrow();
        let view = webview.as_ref().ok_or("no page is loaded")?;
        let host = Rc::clone(&self.page.host);
        view.take_screenshot(None, move |result| match result {
            Ok(image) => match image.save(&path) {
                Ok(()) => host.console(2, &format!("lepton-servo: screenshot {path}")),
                Err(error) => host.console(4, &format!("lepton-servo: screenshot {path}: {error}")),
            },
            Err(error) => host.console(4, &format!("lepton-servo: screenshot: {error:?}")),
        });
        Ok(())
    }
}

/// The CSS name of `cursor` (CSS UI 4 `cursor`), which freedesktop cursor themes use too.
fn css_cursor(cursor: Cursor) -> &'static str {
    match cursor {
        Cursor::None => "none",
        Cursor::Default => "default",
        Cursor::Pointer => "pointer",
        Cursor::ContextMenu => "context-menu",
        Cursor::Help => "help",
        Cursor::Progress => "progress",
        Cursor::Wait => "wait",
        Cursor::Cell => "cell",
        Cursor::Crosshair => "crosshair",
        Cursor::Text => "text",
        Cursor::VerticalText => "vertical-text",
        Cursor::Alias => "alias",
        Cursor::Copy => "copy",
        Cursor::Move => "move",
        Cursor::NoDrop => "no-drop",
        Cursor::NotAllowed => "not-allowed",
        Cursor::Grab => "grab",
        Cursor::Grabbing => "grabbing",
        Cursor::EResize => "e-resize",
        Cursor::NResize => "n-resize",
        Cursor::NeResize => "ne-resize",
        Cursor::NwResize => "nw-resize",
        Cursor::SResize => "s-resize",
        Cursor::SeResize => "se-resize",
        Cursor::SwResize => "sw-resize",
        Cursor::WResize => "w-resize",
        Cursor::EwResize => "ew-resize",
        Cursor::NsResize => "ns-resize",
        Cursor::NeswResize => "nesw-resize",
        Cursor::NwseResize => "nwse-resize",
        Cursor::ColResize => "col-resize",
        Cursor::RowResize => "row-resize",
        Cursor::AllScroll => "all-scroll",
        Cursor::ZoomIn => "zoom-in",
        Cursor::ZoomOut => "zoom-out",
    }
}

#[cfg(test)]
mod tests {
    use super::{button, modifiers};
    use keyboard_types::Modifiers;
    use servo::MouseButton;

    #[test]
    fn buttons_and_modifiers_follow_the_header() {
        assert!(matches!(button(0), MouseButton::Primary));
        assert!(matches!(button(2), MouseButton::Secondary));
        assert_eq!(modifiers(1 | 2), Modifiers::SHIFT | Modifiers::CONTROL);
        assert_eq!(modifiers(4 | 8), Modifiers::ALT | Modifiers::META);
    }
}
