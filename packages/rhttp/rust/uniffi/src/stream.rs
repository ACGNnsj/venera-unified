//! Streaming downloads for non-Flutter hosts.
//!
//! uniffi has no async iterator, so the stream is modelled as a puller:
//! [`RhttpClient::send_stream`] resolves once the response head is available and
//! hands back a [`ResponseStream`]; the host then awaits `nextChunk()` until it
//! returns null. Kotlin wraps that loop in a `flow`, Swift in an
//! `AsyncSequence`. No Rust thread ever calls back into host code, so a slow or
//! buggy host cannot re-enter the transport.
//!
//! Cancellation is cooperative and covered by two tokens: dropping the handle
//! or calling [`ResponseStream::cancel`] stops this transfer, and
//! `cancelAll()` on the client stops every transfer made through it, including
//! bodies that already started.

use std::sync::Arc;

use rhttp_core::{CoreExpectBody, CoreRequest, CoreResponseBody};
use tokio::sync::{mpsc, Mutex};
use tokio_util::sync::CancellationToken;

use crate::{HttpRequest, RhttpClient, RhttpError, RhttpHeader};

/// How many chunks may queue between the transport and the host before reading
/// pauses. Bounded on purpose: a host that stops calling `nextChunk` must apply
/// backpressure instead of letting a whole file pile up in memory.
const CHUNK_BUFFER: usize = 4;

/// The part of a response that arrives before the body.
#[derive(Clone, Debug, uniffi::Record)]
pub struct ResponseHead {
    pub status_code: u16,
    pub headers: Vec<RhttpHeader>,
    pub remote_ip: Option<String>,
}

/// A response whose body is still arriving.
#[derive(uniffi::Object)]
pub struct ResponseStream {
    head: ResponseHead,
    rx: Mutex<mpsc::Receiver<Result<Vec<u8>, RhttpError>>>,
    cancel: CancellationToken,
    client_cancel: CancellationToken,
}

impl ResponseStream {
    fn stopped(&self) -> bool {
        self.cancel.is_cancelled() || self.client_cancel.is_cancelled()
    }
}

impl Drop for ResponseStream {
    fn drop(&mut self) {
        // Dropping the handle must not leave the transfer running.
        self.cancel.cancel();
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl ResponseStream {
    pub fn head(&self) -> ResponseHead {
        self.head.clone()
    }

    /// Next chunk, or null once the body is complete.
    ///
    /// Errors terminate the stream: the host should stop calling `nextChunk`
    /// after any error, including `RhttpError.Cancelled`. Cancellation is
    /// reported as an error rather than as a normal end, so a download that was
    /// interrupted is never mistaken for a complete one.
    pub async fn next_chunk(&self) -> Result<Option<Vec<u8>>, RhttpError> {
        if self.stopped() {
            return Err(RhttpError::Cancelled);
        }
        // `tokio::sync::Mutex` rather than a std one: the guard is held across
        // the await, and uniffi polls this future on the tokio runtime.
        let mut rx = self.rx.lock().await;
        match rx.recv().await {
            Some(Ok(chunk)) => Ok(Some(chunk)),
            Some(Err(error)) => Err(error),
            // The pump ended. Distinguish "finished" from "we stopped it".
            None if self.stopped() => Err(RhttpError::Cancelled),
            None => Ok(None),
        }
    }

    /// Stop this transfer. Idempotent, and safe to call while `nextChunk` is
    /// pending: the pending call resolves with `RhttpError.Cancelled`.
    pub fn cancel(&self) {
        self.cancel.cancel();
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl RhttpClient {
    /// Start a streaming request. Resolves once the response head arrives, so
    /// a status error surfaces here instead of at the first chunk.
    pub async fn send_stream(
        &self,
        request: HttpRequest,
    ) -> Result<Arc<ResponseStream>, RhttpError> {
        self.stream_inner(request.into_core(CoreExpectBody::Stream))
            .await
    }

    /// Streaming GET for the common case.
    pub async fn stream_get(&self, url: String) -> Result<Arc<ResponseStream>, RhttpError> {
        self.stream_inner(HttpRequest::get(url).into_core(CoreExpectBody::Stream))
            .await
    }
}

impl RhttpClient {
    async fn stream_inner(&self, request: CoreRequest) -> Result<Arc<ResponseStream>, RhttpError> {
        let response = self.execute(request).await?;

        let head = ResponseHead {
            status_code: response.status_code,
            headers: response
                .headers
                .into_iter()
                .map(|(name, value)| RhttpHeader { name, value })
                .collect(),
            remote_ip: response.remote_ip,
        };

        let body = match response.body {
            CoreResponseBody::Stream(stream) => stream,
            CoreResponseBody::Text(_) | CoreResponseBody::Bytes(_) => {
                return Err(RhttpError::Network {
                    detail: "expected a streaming body".to_string(),
                })
            }
        };

        let (tx, rx) = mpsc::channel(CHUNK_BUFFER);
        let cancel = CancellationToken::new();
        let client_cancel = self.inner.cancel_token.clone();
        tokio::spawn(pump(body, tx, cancel.clone(), client_cancel.clone()));

        Ok(Arc::new(ResponseStream {
            head,
            rx: Mutex::new(rx),
            cancel,
            client_cancel,
        }))
    }
}

async fn pump(
    mut body: rhttp_core::ByteStream,
    tx: mpsc::Sender<Result<Vec<u8>, RhttpError>>,
    cancel: CancellationToken,
    client_cancel: CancellationToken,
) {
    loop {
        let item = tokio::select! {
            _ = cancel.cancelled() => break,
            _ = client_cancel.cancelled() => break,
            item = rhttp_core::next_chunk(&mut body) => item,
        };

        match item {
            Some(Ok(chunk)) => {
                if tx.send(Ok(chunk)).await.is_err() {
                    // The host dropped the handle.
                    break;
                }
            }
            Some(Err(error)) => {
                let _ = tx.send(Err(RhttpError::from(error))).await;
                break;
            }
            None => break,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::default_client_options;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    /// Serve one chunked body, flushing each chunk separately.
    async fn chunked_server(chunks: &'static [&'static str], gap: Duration) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind a loopback listener");
        let port = listener
            .local_addr()
            .expect("read the listener address")
            .port();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept one connection");
            let mut buf = [0u8; 4096];
            let _ = socket.read(&mut buf).await;
            socket
                .write_all(
                    b"HTTP/1.1 200 OK\r\n\
                      Content-Type: text/plain\r\n\
                      Transfer-Encoding: chunked\r\n\
                      Connection: close\r\n\r\n",
                )
                .await
                .expect("write the response head");
            for chunk in chunks {
                let framed = format!("{:x}\r\n{chunk}\r\n", chunk.len());
                socket
                    .write_all(framed.as_bytes())
                    .await
                    .expect("write a chunk");
                tokio::time::sleep(gap).await;
            }
            socket
                .write_all(b"0\r\n\r\n")
                .await
                .expect("write the terminator");
            // Hold the connection open long enough for the client to observe
            // the end of the body without seeing EOF first.
            tokio::time::sleep(Duration::from_millis(200)).await;
        });
        port
    }

    /// Accept, answer with a single chunk, then stall.
    async fn stalled_server(chunk: &'static str) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind a loopback listener");
        let port = listener
            .local_addr()
            .expect("read the listener address")
            .port();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept one connection");
            let mut buf = [0u8; 4096];
            let _ = socket.read(&mut buf).await;
            socket
                .write_all(
                    b"HTTP/1.1 200 OK\r\n\
                      Transfer-Encoding: chunked\r\n\
                      Connection: close\r\n\r\n",
                )
                .await
                .expect("write the response head");
            let framed = format!("{:x}\r\n{chunk}\r\n", chunk.len());
            socket
                .write_all(framed.as_bytes())
                .await
                .expect("write a chunk");
            tokio::time::sleep(Duration::from_secs(30)).await;
        });
        port
    }

    #[tokio::test]
    async fn stream_delivers_chunks_in_order_and_reports_the_head() {
        let port = chunked_server(&["hello", " world"], Duration::from_millis(200)).await;
        let client = RhttpClient::new(default_client_options()).expect("client builds");

        let handle = client
            .stream_get(format!("http://127.0.0.1:{port}/"))
            .await
            .expect("stream opens");

        let head = handle.head();
        assert_eq!(head.status_code, 200);
        assert!(
            head.headers
                .iter()
                .any(|header| header.name.eq_ignore_ascii_case("content-type")
                    && header.value == "text/plain"),
            "missing content-type in {:?}",
            head.headers
        );

        // The second chunk is written 200 ms later, so the first poll can only
        // see the first one: this is what makes the stream incremental.
        let first = handle
            .next_chunk()
            .await
            .expect("first chunk")
            .expect("first chunk is not the end");
        assert_eq!(first, b"hello");

        let second = handle
            .next_chunk()
            .await
            .expect("second chunk")
            .expect("second chunk is not the end");
        assert_eq!(second, b" world");

        assert!(
            handle.next_chunk().await.expect("end of stream").is_none(),
            "the stream must end"
        );
    }

    #[tokio::test]
    async fn cancel_reports_cancelled_instead_of_a_short_body() {
        let port = stalled_server("partial").await;
        let client = RhttpClient::new(default_client_options()).expect("client builds");
        let handle = client
            .stream_get(format!("http://127.0.0.1:{port}/"))
            .await
            .expect("stream opens");

        assert_eq!(
            handle.next_chunk().await.expect("first chunk"),
            Some(b"partial".to_vec())
        );

        handle.cancel();

        match handle.next_chunk().await {
            Err(RhttpError::Cancelled) => {}
            other => panic!("expected cancellation, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn cancel_all_stops_a_body_that_already_started() {
        let port = stalled_server("partial").await;
        let client = RhttpClient::new(default_client_options()).expect("client builds");
        let handle = client
            .stream_get(format!("http://127.0.0.1:{port}/"))
            .await
            .expect("stream opens");

        assert_eq!(
            handle.next_chunk().await.expect("first chunk"),
            Some(b"partial".to_vec())
        );

        client.cancel_all();

        match handle.next_chunk().await {
            Err(RhttpError::Cancelled) => {}
            other => panic!("expected cancellation, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn status_errors_surface_when_the_stream_opens() {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind a loopback listener");
        let port = listener
            .local_addr()
            .expect("read the listener address")
            .port();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept one connection");
            let mut buf = [0u8; 4096];
            let _ = socket.read(&mut buf).await;
            socket
                .write_all(
                    b"HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\nConnection: close\r\n\r\nbad",
                )
                .await
                .expect("write the response");
        });

        let client = RhttpClient::new(default_client_options()).expect("client builds");
        let error = match client.stream_get(format!("http://127.0.0.1:{port}/")).await {
            Ok(_) => panic!("expected a status-code error"),
            Err(error) => error,
        };
        match error {
            RhttpError::Status { status_code, .. } => assert_eq!(status_code, 404),
            other => panic!("expected a status error, got {other:?}"),
        }
    }
}
