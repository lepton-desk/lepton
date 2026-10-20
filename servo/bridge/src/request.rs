//! One request as the core holds it: counted, answered at most once.
//!
//! The same rules the core's bridge was written against for WebKit's
//! `WebKitURISchemeRequest` and WebView2's deferral (`render/webview/request.zig`):
//! `ref` keeps it, `unref` drops it, and the last `unref` of one never answered answers
//! 500, so a page is never left waiting on a request the core forgot.

use std::cell::{Cell, RefCell};

use tokio::sync::oneshot;

use crate::scheme::{Pending, Reply};

pub struct Request {
    pub url: String,
    pub method: String,
    pub body: Vec<u8>,
    reply: RefCell<Option<oneshot::Sender<Reply>>>,
    references: Cell<u32>,
}

impl Request {
    pub fn new(pending: Pending) -> Self {
        Self {
            url: pending.url,
            method: pending.method,
            body: pending.body,
            reply: RefCell::new(Some(pending.reply)),
            references: Cell::new(1),
        }
    }

    /// Answers the request. A second answer is ignored.
    pub fn respond(&self, status: u16, content_type: &str, allow_origin: &str, bytes: &[u8]) {
        if let Some(reply) = self.reply.borrow_mut().take() {
            let _ = reply.send(Reply {
                status,
                content_type: content_type.to_owned(),
                allow_origin: allow_origin.to_owned(),
                bytes: bytes.to_vec(),
            });
        }
    }

    pub fn reference(&self) {
        self.references.set(self.references.get().saturating_add(1));
    }

    /// Drops one reference; true when it was the last, and the caller frees it.
    pub fn release(&self) -> bool {
        let left = self.references.get().saturating_sub(1);
        self.references.set(left);
        if left == 0 {
            self.respond(
                500,
                "text/plain; charset=utf-8",
                "",
                b"the core never answered",
            );
        }
        left == 0
    }

    #[cfg(test)]
    pub fn answered(&self) -> bool {
        self.reply.borrow().is_none()
    }
}

#[cfg(test)]
mod tests {
    use super::Request;
    use crate::scheme::Pending;
    use tokio::sync::oneshot;

    fn request() -> (Request, oneshot::Receiver<crate::scheme::Reply>) {
        let (reply, answer) = oneshot::channel();
        let pending = Pending {
            url: "lepton://localhost/".into(),
            method: "GET".into(),
            body: Vec::new(),
            reply,
        };
        (Request::new(pending), answer)
    }

    #[test]
    fn the_first_answer_wins() {
        let (request, mut answer) = request();
        request.respond(200, "text/plain", "", b"one");
        request.respond(404, "text/plain", "", b"two");
        assert!(request.answered());
        assert!(
            matches!(answer.try_recv(), Ok(reply) if reply.status == 200 && reply.bytes == b"one")
        );
    }

    #[test]
    fn the_last_unref_of_an_unanswered_request_answers_500() {
        let (request, mut answer) = request();
        request.reference();
        assert!(!request.release(), "one reference is still held");
        assert!(!request.answered());
        assert!(request.release(), "that was the last");
        assert!(matches!(answer.try_recv(), Ok(reply) if reply.status == 500));
    }
}
