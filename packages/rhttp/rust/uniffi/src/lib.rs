//! uniffi bindings for [`rhttp_core`].
//!
//! The exported surface is deliberately small: a client object, an error enum,
//! and the full [`ClientOptions`] mirror of `rhttp_core::ClientSettings`. No
//! Flutter Rust Bridge type is referenced here; both bindings share the same
//! core crate.

mod settings;

uniffi::setup_scaffolding!();

pub use settings::*;

use std::sync::Arc;

use rhttp_core::{CoreError, CoreErrorBody, CoreExpectBody, CoreRequest, CoreResponseBody};
use tokio_util::sync::CancellationToken;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RhttpError {
    #[error("network error: {message}")]
    Network { message: String },

    #[error("status {status_code}: {message}")]
    Status { status_code: u16, message: String },

    #[error("cancelled")]
    Cancelled,

    /// A [`ClientOptions`] value could not be represented by the core type.
    #[error("invalid settings: {message}")]
    InvalidSettings { message: String },
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
                    message,
                }
            }
            other => RhttpError::Network {
                message: other.to_string(),
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

    pub async fn fetch_text(&self, url: String) -> Result<String, RhttpError> {
        let request = self.request(url, CoreExpectBody::Text);
        let response = self.execute(request).await?;
        match response.body {
            CoreResponseBody::Text(text) => Ok(text),
            CoreResponseBody::Bytes(bytes) => Ok(String::from_utf8_lossy(&bytes).into_owned()),
            CoreResponseBody::Stream(_) => Err(RhttpError::Network {
                message: "expected text, got stream".to_string(),
            }),
        }
    }

    pub async fn fetch_bytes(&self, url: String) -> Result<Vec<u8>, RhttpError> {
        let request = self.request(url, CoreExpectBody::Bytes);
        let response = self.execute(request).await?;
        match response.body {
            CoreResponseBody::Text(text) => Ok(text.into_bytes()),
            CoreResponseBody::Bytes(bytes) => Ok(bytes),
            CoreResponseBody::Stream(_) => Err(RhttpError::Network {
                message: "expected bytes, got stream".to_string(),
            }),
        }
    }

    /// Cancel every request made through this client.
    pub fn cancel_all(&self) {
        self.inner.cancel_token.cancel();
    }
}

impl RhttpClient {
    fn request(&self, url: String, expect_body: CoreExpectBody) -> CoreRequest {
        CoreRequest {
            method: "GET".to_string(),
            url,
            query: None,
            headers: None,
            body: None,
            body_stream: None,
            expect_body,
        }
    }

    async fn execute(
        &self,
        request: CoreRequest,
    ) -> Result<rhttp_core::CoreResponse, RhttpError> {
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
        let port = listener.local_addr().expect("read the listener address").port();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept one connection");
            let mut buf = [0u8; 4096];
            let _ = socket.read(&mut buf).await;
            socket.write_all(response).await.expect("write the response");
        });
        port
    }

    #[tokio::test]
    async fn client_built_from_uniffi_options_fetches_text() {
        let port = serve_once(
            b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello",
        )
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
                message,
            } => {
                assert_eq!(status_code, 404);
                assert_eq!(message, "bad");
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
        let port = listener.local_addr().expect("read the listener address").port();
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
}
