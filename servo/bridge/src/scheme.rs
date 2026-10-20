//! The app's scheme, as a Servo protocol handler that asks the core.
//!
//! Servo calls `load` on its fetch runtime, off the core's thread. Each request is
//! queued with its body and a one-shot reply, the core is woken, and the core takes the
//! queue on its own thread (`Engine::spin`). The body arrives as a stream over IPC
//! (`load_web_resource` gives an embedder none), so it is read first, on a thread of
//! its own: every chunk is a blocking receive (measured working in `probes/servo`).

use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use http::HeaderValue;
use ipc_channel::ipc::IpcSender;
use net_traits::request::{BodyChunkRequest, BodyChunkResponse};
use net_traits::{NetworkError, ResourceFetchTiming};
use servo::protocol_handler::{
    DoneChannel, FetchContext, HttpStatus, ProtocolHandler, Request, Response, ResponseBody,
};
use tokio::sync::oneshot;

/// The core's answer to one request.
pub struct Reply {
    pub status: u16,
    pub content_type: String,
    /// The one origin allowed to read the answer cross-origin, or empty.
    pub allow_origin: String,
    pub bytes: Vec<u8>,
}

/// A request waiting for the core to take it.
pub struct Pending {
    pub url: String,
    pub method: String,
    pub body: Vec<u8>,
    pub reply: oneshot::Sender<Reply>,
}

/// Requests from Servo's threads to the core's, and how to wake the core.
pub struct Queue {
    items: Mutex<VecDeque<Pending>>,
    wake: Box<dyn Fn() + Send + Sync>,
}

impl Queue {
    pub fn new(wake: Box<dyn Fn() + Send + Sync>) -> Self {
        Self {
            items: Mutex::new(VecDeque::new()),
            wake,
        }
    }

    fn push(&self, pending: Pending) {
        if let Ok(mut items) = self.items.lock() {
            items.push_back(pending);
        }
        (self.wake)();
    }

    pub fn wake(&self) {
        (self.wake)();
    }

    /// Everything queued so far, oldest first.
    pub fn take(&self) -> Vec<Pending> {
        match self.items.lock() {
            Ok(mut items) => items.drain(..).collect(),
            Err(_) => Vec::new(),
        }
    }
}

pub struct Scheme {
    pub queue: Arc<Queue>,
}

type FutureResponse<'a> = Pin<Box<dyn Future<Output = Response> + Send + 'a>>;

impl ProtocolHandler for Scheme {
    fn load<'a>(
        &'a self,
        request: &'a mut Request,
        _done: &mut DoneChannel,
        _context: &FetchContext,
    ) -> FutureResponse<'a> {
        let url = request.current_url();
        let timing = ResourceFetchTiming::new(request.timing_type());
        let method = request.method.as_str().to_owned();
        let stream = request.body.as_ref().map(|body| body.clone_stream());
        let queue = Arc::clone(&self.queue);

        Box::pin(async move {
            let body = match stream {
                None => Vec::new(),
                Some(stream) => {
                    let (done, received) = oneshot::channel();
                    std::thread::spawn(move || {
                        let _ = done.send(read_body(&stream));
                    });
                    match received.await {
                        Ok(Ok(body)) => body,
                        Ok(Err(reason)) => return failed(reason),
                        Err(_) => return failed("the body reader stopped".into()),
                    }
                }
            };
            let (reply, answer) = oneshot::channel();
            queue.push(Pending {
                url: url.as_str().to_owned(),
                method,
                body,
                reply,
            });
            let Ok(answer) = answer.await else {
                return failed("the core dropped the request".into());
            };
            let mut response = Response::new(url, timing);
            *response.body.lock() = ResponseBody::Done(answer.bytes);
            if let Ok(value) = HeaderValue::from_str(&answer.content_type) {
                response.headers.insert(http::header::CONTENT_TYPE, value);
            }
            // As the WPE and WebView2 halves answer: the frames change on every read.
            response.headers.insert(
                http::header::CACHE_CONTROL,
                HeaderValue::from_static("no-store"),
            );
            if !answer.allow_origin.is_empty() {
                if let Ok(value) = HeaderValue::from_str(&answer.allow_origin) {
                    response
                        .headers
                        .insert(http::header::ACCESS_CONTROL_ALLOW_ORIGIN, value);
                    response
                        .headers
                        .insert(http::header::VARY, HeaderValue::from_static("Origin"));
                }
            }
            response.status = HttpStatus::new_raw(answer.status, Vec::new());
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

fn failed(reason: String) -> Response {
    Response::network_error(NetworkError::ResourceLoadError(reason))
}

/// The body stream as `RequestBody::clone_stream` shares it.
type Stream = Arc<parking_lot::Mutex<Option<IpcSender<BodyChunkRequest>>>>;

fn send(stream: &Stream, message: BodyChunkRequest) -> Result<(), String> {
    let mut guard = stream.lock();
    let sender = guard.as_mut().ok_or("the body stream is closed")?;
    sender
        .send(message)
        .map_err(|error| format!("body stream: {error:?}"))
}

/// Reads a request body's stream to its end: connect, then one chunk at a time, the
/// way Servo's own HTTP loader does (`obtain_response_setup_router_callback`).
fn read_body(stream: &Stream) -> Result<Vec<u8>, String> {
    let (sender, receiver) = ipc_channel::ipc::channel::<BodyChunkResponse>()
        .map_err(|error| format!("ipc channel: {error}"))?;
    send(stream, BodyChunkRequest::Connect(sender))?;
    send(stream, BodyChunkRequest::Chunk)?;
    let mut bytes = Vec::new();
    loop {
        match receiver.recv() {
            Ok(BodyChunkResponse::Chunk(chunk)) => {
                bytes.extend_from_slice(&chunk);
                send(stream, BodyChunkRequest::Chunk)?;
            }
            Ok(BodyChunkResponse::Done) => return Ok(bytes),
            Ok(BodyChunkResponse::Error) => return Err("the page's body stream failed".into()),
            Err(error) => return Err(format!("receive: {error:?}")),
        }
    }
}
