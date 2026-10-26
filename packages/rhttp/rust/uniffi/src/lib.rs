//! uniffi bindings for [`rhttp_core`].
//!
//! The exported surface is deliberately small: a client object, an error enum,
//! and the full [`ClientOptions`] mirror of `rhttp_core::ClientSettings`. No
//! Flutter Rust Bridge type is referenced here; both bindings share the same
//! core crate.

mod request;
mod settings;
mod stream;

#[cfg(test)]
mod test_server;

uniffi::setup_scaffolding!();

pub use request::*;
pub use settings::*;
pub use stream::*;

use std::sync::Arc;

use rhttp_core::{CoreError, CoreErrorBody, CoreExpectBody, CoreRequest, CoreResponseBody};
use tokio_util::sync::CancellationToken;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RhttpError {
    #[error("network error: {detail}")]
    Network { detail: String },

    #[error("status {status_code}: {detail}")]
    Status { status_code: u16, detail: String },

    #[error("cancelled")]
    Cancelled,

    /// A `ClientOptions` value could not be represented by the core type.
    #[error("invalid settings: {detail}")]
    InvalidSettings { detail: String },
}

impl From<CoreError> for RhttpError {
    fn from(error: CoreError) -> Self {
        match error {
            CoreError::Cancelled => RhttpError::Cancelled,
            CoreError::StatusCode(status_code, headers, body) => {
                let message = match body {
                    CoreErrorBody::Text(text) => text,
                    CoreErrorBody::Bytes(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
                    CoreErrorBody::Stream => {
                        let rendered = headers
                            .into_iter()
                            .map(|(name, value)| format!("{name}: {value}"))
                            .collect::<Vec<_>>()
                            .join(", ");
                        format!("status body is a stream ({rendered})")
                    }
                };
                RhttpError::Status {
                    status_code,
                    detail: message,
                }
            }
            other => RhttpError::Network {
                detail: other.to_string(),
            },
        }
    }
}

#[derive(uniffi::Object)]
pub struct RhttpClient {
    inner: rhttp_core::CoreRequestClient,
}

#[uniffi::export(async_runtime = "tokio")]
impl RhttpClient {
    #[uniffi::constructor]
    pub fn new(options: ClientOptions) -> Result<Arc<Self>, RhttpError> {
        let inner = rhttp_core::build_client(options.into_core()?).map_err(RhttpError::from)?;
        Ok(Arc::new(Self { inner }))
    }

    /// Fetch a URL as text. Convenience over `sendText`.
    pub async fn fetch_text(&self, url: String) -> Result<String, RhttpError> {
        self.send_text(HttpRequest::get(url)).await
    }

    /// Fetch a URL as bytes. Convenience over `sendBytes`.
    pub async fn fetch_bytes(&self, url: String) -> Result<Vec<u8>, RhttpError> {
        self.send_bytes(HttpRequest::get(url)).await
    }

    /// Send any request and read the whole body as text.
    pub async fn send_text(&self, request: HttpRequest) -> Result<String, RhttpError> {
        let response = self
            .execute(request.into_core(CoreExpectBody::Text))
            .await?;
        match response.body {
            CoreResponseBody::Text(text) => Ok(text),
            CoreResponseBody::Bytes(bytes) => Ok(String::from_utf8_lossy(&bytes).into_owned()),
            CoreResponseBody::Stream(_) => Err(RhttpError::Network {
                detail: "expected text, got stream".to_string(),
            }),
        }
    }

    /// Send any request and read the whole body as bytes.
    pub async fn send_bytes(&self, request: HttpRequest) -> Result<Vec<u8>, RhttpError> {
        let response = self
            .execute(request.into_core(CoreExpectBody::Bytes))
            .await?;
        match response.body {
            CoreResponseBody::Text(text) => Ok(text.into_bytes()),
            CoreResponseBody::Bytes(bytes) => Ok(bytes),
            CoreResponseBody::Stream(_) => Err(RhttpError::Network {
                detail: "expected bytes, got stream".to_string(),
            }),
        }
    }

    /// Cancel every request made through this client.
    pub fn cancel_all(&self) {
        self.inner.cancel_token.cancel();
    }
}

impl RhttpClient {
    async fn execute(&self, request: CoreRequest) -> Result<rhttp_core::CoreResponse, RhttpError> {
        rhttp_core::execute(
            Some(self.inner.clone()),
            None,
            request,
            CancellationToken::new(),
            self.inner.cancel_token.clone(),
        )
        .await
        .map_err(RhttpError::from)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    async fn serve_once(response: &'static [u8]) -> u16 {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
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
                .write_all(response)
                .await
                .expect("write the response");
        });
        port
    }

    #[tokio::test]
    async fn client_built_from_uniffi_options_fetches_text() {
        let port =
            serve_once(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
                .await;

        let mut options = default_client_options();
        options.user_agent = Some("rhttp-uniffi/0.1".to_string());
        let client = RhttpClient::new(options).expect("client builds from uniffi options");

        let body = client
            .fetch_text(format!("http://127.0.0.1:{port}/"))
            .await
            .expect("text body");
        assert_eq!(body, "hello");
    }

    #[tokio::test]
    async fn status_errors_surface_as_the_status_variant() {
        let port = serve_once(
            b"HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\nConnection: close\r\n\r\nbad",
        )
        .await;

        let client = RhttpClient::new(default_client_options()).expect("client builds");

        let error = match client.fetch_text(format!("http://127.0.0.1:{port}/")).await {
            Ok(_) => panic!("expected a status-code error"),
            Err(error) => error,
        };
        match error {
            RhttpError::Status {
                status_code,
                detail,
            } => {
                assert_eq!(status_code, 404);
                assert_eq!(detail, "bad");
            }
            other => panic!("expected a status error, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn timeout_settings_reach_the_undersized_transport() {
        // The listener accepts but never answers, so the request must be
        // cancelled by the client timeout configured through ClientOptions.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind a loopback listener");
        let port = listener
            .local_addr()
            .expect("read the listener address")
            .port();
        tokio::spawn(async move {
            let (_socket, _) = listener.accept().await.expect("accept one connection");
            tokio::time::sleep(std::time::Duration::from_secs(30)).await;
        });

        let mut options = default_client_options();
        options.timeout_settings = Some(TimeoutSettings {
            timeout: Some(std::time::Duration::from_millis(150)),
            connect_timeout: None,
            keep_alive_timeout: None,
            keep_alive_ping: None,
        });
        let client = RhttpClient::new(options).expect("client builds");

        let error = match client.fetch_text(format!("http://127.0.0.1:{port}/")).await {
            Ok(_) => panic!("expected a timeout"),
            Err(error) => error,
        };
        assert!(
            matches!(error, RhttpError::Network { .. }),
            "a timeout is reported as a network error, got {error:?}"
        );
    }

    use crate::test_server::capture_one;

    fn field(name: &str, value: &str) -> RhttpField {
        RhttpField {
            name: name.to_string(),
            value: value.to_string(),
        }
    }

    #[tokio::test]
    async fn post_text_body_reaches_the_server() {
        let (port, captured) = capture_one().await;
        let client = RhttpClient::new(default_client_options()).expect("client builds");

        let request = HttpRequest {
            url: format!("http://127.0.0.1:{port}/echo"),
            method: Some("POST".to_string()),
            headers: vec![RhttpHeader {
                name: "x-upload".to_string(),
                value: "1".to_string(),
            }],
            query: vec![field("q", "a b")],
            body: Some(RequestBody::Text {
                text: "hello body".to_string(),
            }),
        };
        assert_eq!(
            client.send_text(request).await.expect("response body"),
            "ok"
        );

        let captured = captured.await.expect("the server captured the request");
        assert_eq!(captured.method, "POST");
        assert!(
            captured.target.starts_with("/echo?q=a"),
            "query string missing or unencoded: {}",
            captured.target
        );
        assert_eq!(captured.header("x-upload"), Some("1"));
        assert_eq!(captured.body_text(), "hello body");
    }

    #[tokio::test]
    async fn form_bodies_are_url_encoded() {
        let (port, captured) = capture_one().await;
        let client = RhttpClient::new(default_client_options()).expect("client builds");

        let request = HttpRequest {
            url: format!("http://127.0.0.1:{port}/form"),
            method: Some("POST".to_string()),
            headers: Vec::new(),
            query: Vec::new(),
            body: Some(RequestBody::Form {
                fields: vec![field("a", "1"), field("b", "two words")],
            }),
        };
        client.send_text(request).await.expect("response body");

        let captured = captured.await.expect("the server captured the request");
        assert_eq!(
            captured.header("content-type"),
            Some("application/x-www-form-urlencoded"),
            "form bodies must be encoded by the transport"
        );
        // Core stores form fields in a map, so the order is not part of the
        // contract; the encoding is.
        let body = captured.body_text();
        let mut pairs: Vec<&str> = body.split('&').collect();
        pairs.sort_unstable();
        assert_eq!(pairs, vec!["a=1", "b=two+words"]);
    }

    #[tokio::test]
    async fn multipart_uploads_carry_text_and_file_parts() {
        let path = std::env::temp_dir().join("rhttp-uniffi-multipart-part.txt");
        std::fs::write(&path, b"file contents").expect("write the upload fixture");

        let (port, captured) = capture_one().await;
        let client = RhttpClient::new(default_client_options()).expect("client builds");

        let request = HttpRequest {
            url: format!("http://127.0.0.1:{port}/upload"),
            method: Some("POST".to_string()),
            headers: Vec::new(),
            query: Vec::new(),
            body: Some(RequestBody::Multipart {
                payload: MultipartPayload {
                    parts: vec![
                        MultipartPart {
                            name: "title".to_string(),
                            value: MultipartValue::Text {
                                text: "cover".to_string(),
                            },
                            file_name: None,
                            content_type: None,
                        },
                        MultipartPart {
                            name: "file".to_string(),
                            value: MultipartValue::File {
                                path: path.to_string_lossy().into_owned(),
                            },
                            file_name: Some("part.txt".to_string()),
                            content_type: Some("text/plain".to_string()),
                        },
                    ],
                },
            }),
        };
        client.send_text(request).await.expect("response body");

        let captured = captured.await.expect("the server captured the request");
        let content_type = captured
            .header("content-type")
            .expect("a multipart content type");
        assert!(
            content_type.starts_with("multipart/form-data; boundary="),
            "unexpected content type {content_type}"
        );

        let body = captured.body_text();
        assert!(
            body.contains("name=\"title\""),
            "missing the text part: {body}"
        );
        assert!(
            body.contains("\r\n\r\ncover\r\n"),
            "missing the text value: {body}"
        );
        assert!(
            body.contains("filename=\"part.txt\""),
            "missing the file name: {body}"
        );
        assert!(
            body.contains("Content-Type: text/plain"),
            "missing the part content type: {body}"
        );
        assert!(
            body.contains("\r\n\r\nfile contents\r\n"),
            "missing the file bytes: {body}"
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn a_streamed_request_carries_its_body_too() {
        let (port, captured) = capture_one().await;
        let client = RhttpClient::new(default_client_options()).expect("client builds");

        let handle = client
            .send_stream(HttpRequest {
                url: format!("http://127.0.0.1:{port}/stream"),
                method: Some("POST".to_string()),
                headers: Vec::new(),
                query: Vec::new(),
                body: Some(RequestBody::Text {
                    text: "streamed".to_string(),
                }),
            })
            .await
            .expect("stream opens");

        let mut body = Vec::new();
        while let Some(chunk) = handle.next_chunk().await.expect("chunk") {
            body.extend(chunk);
        }
        assert_eq!(body, b"ok");

        let captured = captured.await.expect("the server captured the request");
        assert_eq!(captured.body_text(), "streamed");
    }

    /// A host callback that hands out a fixed list of chunks and then stops.
    struct ChunkSource {
        chunks: std::sync::Mutex<std::collections::VecDeque<Vec<u8>>>,
    }

    impl ChunkSource {
        fn new(chunks: Vec<Vec<u8>>) -> std::sync::Arc<Self> {
            std::sync::Arc::new(Self {
                chunks: std::sync::Mutex::new(chunks.into()),
            })
        }
    }

    #[async_trait::async_trait]
    impl RequestBodySource for ChunkSource {
        async fn next_chunk(&self) -> Option<Vec<u8>> {
            self.chunks.lock().unwrap().pop_front()
        }
    }

    #[tokio::test]
    async fn a_stream_upload_pulls_every_chunk_into_the_request() {
        let (port, captured) = capture_one().await;
        let client = RhttpClient::new(default_client_options()).expect("client builds");

        let request = HttpRequest {
            url: format!("http://127.0.0.1:{port}/upload"),
            method: Some("POST".to_string()),
            headers: Vec::new(),
            query: Vec::new(),
            body: Some(RequestBody::Stream {
                source: ChunkSource::new(vec![b"chunk-one".to_vec(), b"-chunk-two".to_vec()]),
            }),
        };
        client.send_text(request).await.expect("response body");

        let captured = captured.await.expect("the server captured the request");
        assert_eq!(captured.body_text(), "chunk-one-chunk-two");
        // The host stream has no known length, so the transport must fall back
        // to chunked encoding rather than inventing a Content-Length.
        assert_eq!(
            captured.header("transfer-encoding"),
            Some("chunked"),
            "a streamed body should be chunked"
        );
        assert_eq!(
            captured.header("content-length"),
            None,
            "a streamed body must not claim a length"
        );
    }
}
