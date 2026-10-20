//! Can Servo serve a Lepton page and carry its calls?
//!
//! Lepton's page reaches the core through its own scheme: assets come from
//! `lepton://localhost/`, and every call is one binary frame POSTed to
//! `lepton://localhost/__lepton/invoke`, the reply frame being the response
//! (`zig/src/render/webview/invoke.zig`). Servo 0.6's `load_web_resource` hands an
//! embedder no request body, so the only route is a protocol handler, where the body
//! arrives as a stream over IPC. This probe registers `lepton` with Servo, loads a page
//! from it, and has the page POST a binary body (bytes 0 and 255 included) and time 100
//! more calls. The handler answers with the body reversed.
//!
//! It passes (exit 0) only when the handler read the exact bytes the page sent and the
//! page read the exact reply. It prints the timings and writes `servo-probe.png`.
//! Built in CI (`.github/workflows/servo-probe.yml`), never on the project's machine.

use std::cell::{Cell, RefCell};
use std::future::Future;
use std::pin::Pin;
use std::process::ExitCode;
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use dpi::PhysicalSize;
use http::HeaderValue;
use net_traits::request::{BodyChunkRequest, BodyChunkResponse};
use net_traits::{NetworkError, ResourceFetchTiming};
use servo::protocol_handler::{
    DoneChannel, FetchContext, HttpStatus, ProtocolHandler, ProtocolRegistry, Request, Response,
    ResponseBody,
};
use servo::{
    ConsoleLogLevel, EventLoopWaker, RenderingContext, ServoBuilder, SoftwareRenderingContext,
    WebView, WebViewBuilder, WebViewDelegate,
};
use url::Url;

/// The body the page sends first; the handler must read exactly these bytes.
const SENT: [u8; 14] = [0, 1, 2, 3, 127, 128, 250, 255, 76, 101, 112, 116, 111, 110];

const PAGE: &str = r#"<!doctype html>
<meta charset="utf-8">
<title>loading</title>
<body style="font: 22px sans-serif; margin: 40px">
<h1>Lepton on Servo</h1>
<p id="out">calling the core…</p>
<script>
const sent = new Uint8Array([0, 1, 2, 3, 127, 128, 250, 255, 76, 101, 112, 116, 111, 110]);
async function call(body) {
  const response = await fetch("/__lepton/invoke", { method: "POST", body });
  if (!response.ok) throw new Error("status " + response.status);
  return new Uint8Array(await response.arrayBuffer());
}
(async () => {
  try {
    const reply = await call(sent);
    const times = [];
    for (let i = 0; i < 100; i++) {
      const start = performance.now();
      await call(sent);
      times.push(performance.now() - start);
    }
    times.sort((a, b) => a - b);
    const p50 = times[50].toFixed(2);
    const p95 = times[95].toFixed(2);
    document.getElementById("out").textContent =
      "reply " + Array.from(reply).join(",") + " · p50 " + p50 + " ms · p95 " + p95 + " ms";
    document.title = "done reply=" + Array.from(reply).join(",") + " p50=" + p50 + " p95=" + p95;
  } catch (error) {
    document.getElementById("out").textContent = String(error);
    document.title = "error " + error;
  }
})();
</script>
"#;

type FutureResponse<'a> = Pin<Box<dyn Future<Output = Response> + Send + 'a>>;

/// The `lepton` scheme: the page at `/`, calls at `/__lepton/invoke`.
struct Scheme {
    /// Every call body the handler read, in order.
    bodies: Arc<Mutex<Vec<Vec<u8>>>>,
}

impl ProtocolHandler for Scheme {
    fn load<'a>(
        &'a self,
        request: &'a mut Request,
        _done: &mut DoneChannel,
        _context: &FetchContext,
    ) -> FutureResponse<'a> {
        let url = request.current_url();
        let timing = ResourceFetchTiming::new(request.timing_type());
        let path = url.as_url().path().to_owned();
        let stream = request.body.as_ref().map(|body| body.clone_stream());
        let bodies = Arc::clone(&self.bodies);

        Box::pin(async move {
            let (bytes, content_type) = match path.as_str() {
                "/" | "/index.html" => (PAGE.as_bytes().to_vec(), "text/html; charset=utf-8"),
                "/__lepton/invoke" => {
                    let Some(stream) = stream else {
                        return Response::network_error(NetworkError::ResourceLoadError(
                            "invoke without a body".into(),
                        ));
                    };
                    // The stream is read on its own thread: each chunk is a blocking IPC
                    // receive, and this future runs on Servo's fetch runtime.
                    let (done, received) = tokio::sync::oneshot::channel();
                    std::thread::spawn(move || {
                        let read = (|| -> Result<Vec<u8>, String> {
                            let (sender, receiver) =
                                ipc_channel::ipc::channel::<BodyChunkResponse>()
                                    .map_err(|error| format!("ipc channel: {error}"))?;
                            {
                                let mut guard = stream.lock();
                                let requester =
                                    guard.as_mut().ok_or("the body stream is already closed")?;
                                requester
                                    .send(BodyChunkRequest::Connect(sender))
                                    .map_err(|error| format!("connect: {error:?}"))?;
                                requester
                                    .send(BodyChunkRequest::Chunk)
                                    .map_err(|error| format!("first chunk: {error:?}"))?;
                            }
                            let mut bytes = Vec::new();
                            loop {
                                match receiver.recv() {
                                    Ok(BodyChunkResponse::Chunk(chunk)) => {
                                        bytes.extend_from_slice(&chunk);
                                        let mut guard = stream.lock();
                                        let requester = guard
                                            .as_mut()
                                            .ok_or("the body stream closed mid-body")?;
                                        requester
                                            .send(BodyChunkRequest::Chunk)
                                            .map_err(|error| format!("next chunk: {error:?}"))?;
                                    }
                                    Ok(BodyChunkResponse::Done) => return Ok(bytes),
                                    Ok(BodyChunkResponse::Error) => {
                                        return Err("the page's body stream failed".into());
                                    }
                                    Err(error) => return Err(format!("receive: {error:?}")),
                                }
                            }
                        })();
                        let _ = done.send(read);
                    });
                    let body = match received.await {
                        Ok(Ok(body)) => body,
                        Ok(Err(reason)) => {
                            return Response::network_error(NetworkError::ResourceLoadError(
                                reason,
                            ));
                        }
                        Err(_) => {
                            return Response::network_error(NetworkError::ResourceLoadError(
                                "the body reader stopped".into(),
                            ));
                        }
                    };
                    let reply: Vec<u8> = body.iter().rev().copied().collect();
                    if let Ok(mut seen) = bodies.lock() {
                        seen.push(body);
                    }
                    (reply, "application/octet-stream")
                }
                other => {
                    return Response::network_error(NetworkError::ResourceLoadError(format!(
                        "no such path: {other}"
                    )));
                }
            };
            let mut response = Response::new(url, timing);
            *response.body.lock() = ResponseBody::Done(bytes);
            response.headers.insert(
                http::header::CONTENT_TYPE,
                HeaderValue::from_static(content_type),
            );
            response.status = HttpStatus::default();
            response
        })
    }

    fn is_fetchable(&self) -> bool {
        true
    }

    fn is_secure(&self) -> bool {
        true
    }
}

/// What the page reports through its title, and its console.
#[derive(Default)]
struct Page {
    title: RefCell<Option<String>>,
    frames: Cell<u32>,
}

impl WebViewDelegate for Page {
    fn notify_page_title_changed(&self, _webview: WebView, title: Option<String>) {
        *self.title.borrow_mut() = title;
    }

    fn notify_new_frame_ready(&self, webview: WebView) {
        self.frames.set(self.frames.get() + 1);
        webview.paint();
    }

    fn show_console_message(&self, _webview: WebView, level: ConsoleLogLevel, message: String) {
        eprintln!("console {level:?}: {message}");
    }
}

/// The probe spins Servo's loop itself, so a wake-up needs no action.
#[derive(Clone)]
struct Waker;

impl EventLoopWaker for Waker {
    fn clone_box(&self) -> Box<dyn EventLoopWaker> {
        Box::new(self.clone())
    }

    fn wake(&self) {}
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(reason) => {
            eprintln!("servo-probe: {reason}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let started = Instant::now();
    let context = Rc::new(
        SoftwareRenderingContext::new(PhysicalSize {
            width: 800,
            height: 600,
        })
        .map_err(|error| format!("software rendering context: {error:?}"))?,
    );
    context
        .make_current()
        .map_err(|error| format!("make the rendering context current: {error:?}"))?;

    let bodies = Arc::new(Mutex::new(Vec::new()));
    let mut protocols = ProtocolRegistry::default();
    protocols
        .register(
            "lepton",
            Scheme {
                bodies: Arc::clone(&bodies),
            },
        )
        .map_err(|error| format!("register the lepton scheme: {error:?}"))?;

    let servo = ServoBuilder::default()
        .protocol_registry(protocols)
        .event_loop_waker(Box::new(Waker))
        .build();
    let page = Rc::new(Page::default());
    let address = Url::parse("lepton://localhost/").map_err(|error| error.to_string())?;
    let webview = WebViewBuilder::new(&servo, context.clone())
        .delegate(page.clone())
        .url(address)
        .build();
    println!("servo started   {} ms", started.elapsed().as_millis());

    let deadline = Instant::now() + Duration::from_secs(120);
    let title = loop {
        servo.spin_event_loop();
        let current = page.title.borrow().clone();
        if let Some(title) = current.filter(|t| t.starts_with("done ") || t.starts_with("error ")) {
            break title;
        }
        if Instant::now() > deadline {
            return Err(format!(
                "the page did not finish in 120 s; title {:?}",
                page.title.borrow()
            ));
        }
        std::thread::sleep(Duration::from_millis(1));
    };
    println!("page finished   {} ms", started.elapsed().as_millis());
    println!("title           {title}");

    let shot: Rc<RefCell<Option<Result<servo::RgbaImage, String>>>> = Rc::new(RefCell::new(None));
    let slot = Rc::clone(&shot);
    webview.take_screenshot(None, move |result| {
        *slot.borrow_mut() = Some(result.map_err(|error| format!("{error:?}")));
    });
    let deadline = Instant::now() + Duration::from_secs(30);
    while shot.borrow().is_none() && Instant::now() < deadline {
        servo.spin_event_loop();
        std::thread::sleep(Duration::from_millis(1));
    }
    match shot.borrow_mut().take() {
        Some(Ok(image)) => {
            image
                .save("servo-probe.png")
                .map_err(|error| format!("save the screenshot: {error}"))?;
            println!(
                "screenshot      servo-probe.png {}x{}",
                image.width(),
                image.height()
            );
        }
        Some(Err(reason)) => println!("screenshot      failed: {reason}"),
        None => println!("screenshot      none in 30 s"),
    }
    println!("frames          {}", page.frames.get());

    let seen = bodies
        .lock()
        .map_err(|_| "the handler's record is poisoned".to_owned())?
        .clone();
    println!("calls handled   {}", seen.len());
    let first = seen.first().ok_or("no call reached the handler")?;
    if first.as_slice() != SENT {
        return Err(format!(
            "the handler read {first:?}, the page sent {SENT:?}"
        ));
    }
    println!("body            intact ({} bytes)", first.len());
    let expected: Vec<String> = SENT.iter().rev().map(u8::to_string).collect();
    let expected = format!("done reply={} ", expected.join(","));
    if !title.starts_with(&expected) {
        return Err(format!("the page read a different reply: {title}"));
    }
    println!("reply           intact");
    Ok(())
}
