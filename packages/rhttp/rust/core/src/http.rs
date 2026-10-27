use crate::client::{build_client, CoreRequestClient};
use crate::error::{CoreError, CoreErrorBody};
use crate::request::{
    CoreBody, CoreExpectBody, CoreHeaders, CoreHttpVersion, CoreMultipartValue, CoreRequest,
    CoreResponse, CoreResponseBody,
};
use crate::settings::ClientSettings;
use futures_util::StreamExt;
use reqwest::header::{HeaderName, HeaderValue};
use reqwest::{Method, Response, Url, Version};
use std::error::Error as StdError;
use std::str::FromStr;
use tokio_util::sync::CancellationToken;

/// Execute a request. Cancellation covers connection, headers and (for
/// non-streaming calls) the response body. Streaming callers keep ownership
/// of the returned byte stream and can drop it to cancel the transfer.
pub async fn execute(
    client: Option<CoreRequestClient>,
    settings: Option<ClientSettings>,
    request: CoreRequest,
    cancel_token: CancellationToken,
    client_cancel_token: CancellationToken,
) -> Result<CoreResponse, CoreError> {
    tokio::select! {
        _ = cancel_token.cancelled() => Err(CoreError::Cancelled),
        _ = client_cancel_token.cancelled() => Err(CoreError::Cancelled),
        response = execute_inner(client, settings, request) => response,
    }
}

async fn execute_inner(
    client: Option<CoreRequestClient>,
    settings: Option<ClientSettings>,
    request: CoreRequest,
) -> Result<CoreResponse, CoreError> {
    let client = resolve_client(client, settings)?;
    let expect_body = request.expect_body;
    let response = send_request(&client, request).await?;

    let status = response.status();
    let status_code = status.as_u16();
    let headers = header_to_vec(response.headers());
    let version = core_version(response.version());
    let remote_ip = response.remote_addr().map(|addr| addr.ip().to_string());

    if client.throw_on_status_code && (status.is_client_error() || status.is_server_error()) {
        let body = match expect_body {
            CoreExpectBody::Text => {
                CoreErrorBody::Text(response.text().await.map_err(map_reqwest_error)?)
            }
            CoreExpectBody::Bytes => {
                CoreErrorBody::Bytes(response.bytes().await.map_err(map_reqwest_error)?.to_vec())
            }
            CoreExpectBody::Stream => CoreErrorBody::Stream,
        };
        return Err(CoreError::StatusCode(status_code, headers.clone(), body));
    }

    let body = match expect_body {
        CoreExpectBody::Text => {
            CoreResponseBody::Text(response.text().await.map_err(map_reqwest_error)?)
        }
        CoreExpectBody::Bytes => {
            CoreResponseBody::Bytes(response.bytes().await.map_err(map_reqwest_error)?.to_vec())
        }
        CoreExpectBody::Stream => {
            CoreResponseBody::Stream(Box::pin(response.bytes_stream().map(|chunk| {
                chunk
                    .map(|bytes| bytes.to_vec())
                    .map_err(|e| CoreError::Unknown(e.to_string()))
            })))
        }
    };

    Ok(CoreResponse {
        remote_ip,
        headers,
        version,
        status_code,
        body,
    })
}

async fn send_request(
    client: &CoreRequestClient,
    request: CoreRequest,
) -> Result<Response, CoreError> {
    let CoreRequest {
        method,
        url,
        query,
        headers,
        body,
        body_stream,
        ..
    } = request;

    let method = Method::from_bytes(method.as_bytes())
        .map_err(|e| CoreError::Unknown(format!("Invalid method: {e:?}")))?;
    let url = Url::parse(&url).map_err(|e| CoreError::Unknown(e.to_string()))?;
    let mut builder = client.client.request(method, url);

    builder = match client.http_version_pref {
        crate::settings::HttpVersionPref::Http10 => builder.version(Version::HTTP_10),
        crate::settings::HttpVersionPref::Http11 => builder.version(Version::HTTP_11),
        crate::settings::HttpVersionPref::Http2 => builder.version(Version::HTTP_2),
        crate::settings::HttpVersionPref::Http3 => builder.version(Version::HTTP_3),
        crate::settings::HttpVersionPref::All => builder,
    };

    if let Some(query) = query {
        builder = builder.query(&query);
    }

    if let Some(headers) = headers {
        match headers {
            CoreHeaders::Map(map) => {
                for (key, value) in map {
                    let name = HeaderName::from_str(&key)
                        .map_err(|e| CoreError::Unknown(e.to_string()))?;
                    let value = HeaderValue::from_str(&value)
                        .map_err(|e| CoreError::Unknown(e.to_string()))?;
                    builder = builder.header(name, value);
                }
            }
            CoreHeaders::List(list) => {
                for (key, value) in list {
                    let name = HeaderName::from_str(&key)
                        .map_err(|e| CoreError::Unknown(e.to_string()))?;
                    let value = HeaderValue::from_str(&value)
                        .map_err(|e| CoreError::Unknown(e.to_string()))?;
                    builder = builder.header(name, value);
                }
            }
        }
    }

    builder = match body {
        Some(CoreBody::Text(text)) => builder.body(text),
        Some(CoreBody::Bytes(bytes)) => builder.body(bytes),
        Some(CoreBody::BytesStream) => {
            let stream = body_stream.ok_or_else(|| {
                CoreError::Unknown("body_stream should exist for CoreBody::BytesStream".to_string())
            })?;
            let stream = stream.map(|item| item.map(bytes::Bytes::from));
            builder.body(reqwest::Body::wrap_stream(stream))
        }
        Some(CoreBody::Form(form)) => builder.form(&form),
        Some(CoreBody::Multipart(payload)) => {
            let mut form = reqwest::multipart::Form::new();
            for (name, item) in payload.parts {
                let mut part = match item.value {
                    CoreMultipartValue::Text(text) => reqwest::multipart::Part::text(text),
                    CoreMultipartValue::Bytes(bytes) => reqwest::multipart::Part::bytes(bytes),
                    CoreMultipartValue::File(path) => {
                        let file = tokio::fs::File::open(path)
                            .await
                            .map_err(|e| CoreError::Unknown(format!("Failed to open file: {e}")))?;
                        reqwest::multipart::Part::stream(reqwest::Body::wrap_stream(
                            tokio_util::io::ReaderStream::new(file),
                        ))
                    }
                };

                if let Some(file_name) = item.file_name {
                    part = part.file_name(file_name);
                }
                if let Some(content_type) = item.content_type {
                    part = part
                        .mime_str(&content_type)
                        .map_err(|e| CoreError::Unknown(e.to_string()))?;
                }
                form = form.part(name, part);
            }
            builder.multipart(form)
        }
        None => builder,
    };

    let request = builder
        .build()
        .map_err(|e| CoreError::Unknown(e.to_string()))?;

    client
        .client
        .execute(request)
        .await
        .map_err(map_reqwest_error)
}

fn resolve_client(
    client: Option<CoreRequestClient>,
    settings: Option<ClientSettings>,
) -> Result<CoreRequestClient, CoreError> {
    match client {
        Some(client) => Ok(client),
        None => match settings {
            Some(settings) => build_client(settings),
            None => build_client(ClientSettings::default()),
        },
    }
}

fn map_reqwest_error(error: reqwest::Error) -> CoreError {
    if error.is_redirect() {
        return CoreError::Redirect;
    }
    if error.is_timeout() {
        return CoreError::Timeout;
    }

    let inner = error.source();
    let is_cert = inner
        .map(|inner| format!("{inner:?}").contains("InvalidCertificate"))
        .unwrap_or(false);
    let detail = inner
        .map(|inner| format!("{inner:?}"))
        .unwrap_or_else(|| format!("{error:?}"));

    if is_cert {
        CoreError::InvalidCertificate(detail)
    } else if error.is_connect() {
        CoreError::Connection(detail)
    } else {
        CoreError::Unknown(detail)
    }
}

fn header_to_vec(headers: &reqwest::header::HeaderMap) -> Vec<(String, String)> {
    headers
        .iter()
        .filter_map(|(key, value)| match value.to_str() {
            Ok(value) => Some((key.as_str().to_string(), value.to_string())),
            Err(_) => None,
        })
        .collect()
}

fn core_version(version: Version) -> CoreHttpVersion {
    match version {
        Version::HTTP_09 => CoreHttpVersion::Http09,
        Version::HTTP_10 => CoreHttpVersion::Http10,
        Version::HTTP_11 => CoreHttpVersion::Http11,
        Version::HTTP_2 => CoreHttpVersion::Http2,
        Version::HTTP_3 => CoreHttpVersion::Http3,
        _ => CoreHttpVersion::Other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request::{CoreExpectBody, CoreRequest};
    use crate::settings::{
        CustomProxy, HttpVersionPref, ProxyCondition, ProxySettings, TimeoutSettings,
    };
    use futures_util::StreamExt;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio_util::sync::CancellationToken;

    async fn serve_once(response: &'static [u8]) -> u16 {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = [0u8; 4096];
            let _ = socket.read(&mut buf).await;
            socket.write_all(response).await.unwrap();
        });
        port
    }

    fn get_request(port: u16, expect_body: CoreExpectBody) -> CoreRequest {
        CoreRequest {
            method: "GET".to_string(),
            url: format!("http://127.0.0.1:{port}/"),
            query: None,
            headers: None,
            body: None,
            body_stream: None,
            expect_body,
        }
    }

    async fn execute_get(
        port: u16,
        expect_body: CoreExpectBody,
    ) -> Result<CoreResponse, CoreError> {
        execute(
            None,
            Some(ClientSettings::default()),
            get_request(port, expect_body),
            CancellationToken::new(),
            CancellationToken::new(),
        )
        .await
    }

    #[tokio::test]
    async fn text_response_keeps_status_and_body() {
        let port =
            serve_once(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
                .await;

        let response = execute_get(port, CoreExpectBody::Text).await.unwrap();
        assert_eq!(response.status_code, 200);
        match response.body {
            CoreResponseBody::Text(text) => assert_eq!(text, "hello"),
            _ => panic!("expected a text body"),
        }
    }

    #[tokio::test]
    async fn status_error_carries_headers_and_body() {
        let port = serve_once(
            b"HTTP/1.1 404 Not Found\r\nX-Test: yes\r\nContent-Length: 3\r\nConnection: close\r\n\r\nbad",
        )
        .await;

        let error = match execute_get(port, CoreExpectBody::Text).await {
            Ok(_) => panic!("expected a status-code error"),
            Err(error) => error,
        };
        match error {
            CoreError::StatusCode(code, headers, CoreErrorBody::Text(text)) => {
                assert_eq!(code, 404);
                assert!(headers
                    .iter()
                    .any(|(key, value)| key.eq_ignore_ascii_case("x-test") && value == "yes"));
                assert_eq!(text, "bad");
            }
            _ => panic!("expected a status-code error with a text body"),
        }
    }

    #[tokio::test]
    async fn stream_response_yields_bytes() {
        let port =
            serve_once(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
                .await;

        let response = execute_get(port, CoreExpectBody::Stream).await.unwrap();
        let mut stream = match response.body {
            CoreResponseBody::Stream(stream) => stream,
            _ => panic!("expected a stream body"),
        };

        let mut data = Vec::new();
        while let Some(chunk) = stream.next().await {
            data.extend_from_slice(&chunk.unwrap());
        }
        assert_eq!(data, b"hello");
    }

    /// LL-13: the Dart handle pool passes one shared client so the connection
    /// pool (and its keep-alive settings) survives across requests. These
    /// tests pin the `resolve_client` contract that sharing relies on, and
    /// demonstrate the per-request-build waste it eliminates.

    fn unbuildable_settings() -> ClientSettings {
        ClientSettings {
            proxy_settings: Some(ProxySettings::CustomProxyList(vec![CustomProxy {
                url: "http://127.0.0.1:notaport".to_string(),
                condition: ProxyCondition::All,
            }])),
            ..ClientSettings::default()
        }
    }

    #[test]
    fn provided_client_is_reused_without_rebuilding() {
        // Sanity: these settings really cannot build, so resolving Ok below
        // proves the provided client is passed through untouched.
        assert!(build_client(unbuildable_settings()).is_err());

        let shared = build_client(ClientSettings::default()).unwrap();
        let resolved = resolve_client(Some(shared), Some(unbuildable_settings())).unwrap();
        assert_eq!(resolved.http_version_pref, HttpVersionPref::All);
        assert!(resolved.throw_on_status_code);
    }

    #[test]
    fn missing_client_builds_from_settings_or_default() {
        let settings = ClientSettings {
            http_version_pref: HttpVersionPref::Http11,
            throw_on_status_code: false,
            timeout_settings: Some(TimeoutSettings {
                timeout: None,
                connect_timeout: None,
                keep_alive_timeout: Some(chrono::Duration::seconds(60)),
                keep_alive_ping: None,
            }),
            ..ClientSettings::default()
        };
        let resolved = resolve_client(None, Some(settings)).unwrap();
        assert_eq!(resolved.http_version_pref, HttpVersionPref::Http11);
        assert!(!resolved.throw_on_status_code);

        let resolved = resolve_client(None, None).unwrap();
        assert_eq!(resolved.http_version_pref, HttpVersionPref::All);
        assert!(resolved.throw_on_status_code);
    }

    const KEEPALIVE_OK: &[u8] =
        b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nhello";

    /// Loopback server that keeps connections alive and counts TCP accepts.
    async fn serve_keepalive(
        response: &'static [u8],
        accepts: Arc<AtomicUsize>,
    ) -> (u16, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = tokio::spawn(async move {
            loop {
                let (mut socket, _) = match listener.accept().await {
                    Ok(conn) => conn,
                    Err(_) => break,
                };
                accepts.fetch_add(1, Ordering::SeqCst);
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 4096];
                    loop {
                        // Read one request head; a GET has no body.
                        let mut head = Vec::new();
                        let eof = loop {
                            match socket.read(&mut buf).await {
                                Ok(0) => break true,
                                Ok(n) => {
                                    head.extend_from_slice(&buf[..n]);
                                    if head.windows(4).any(|w| w == b"\r\n\r\n") {
                                        break false;
                                    }
                                }
                                Err(_) => break true,
                            }
                        };
                        if eof || socket.write_all(response).await.is_err() {
                            break;
                        }
                    }
                });
            }
        });
        (port, handle)
    }

    #[tokio::test]
    async fn shared_client_reuses_a_single_connection() {
        let accepts = Arc::new(AtomicUsize::new(0));
        let (port, server) = serve_keepalive(KEEPALIVE_OK, accepts.clone()).await;

        let client = build_client(ClientSettings::default()).unwrap();
        for _ in 0..2 {
            let response = execute(
                Some(client.clone()),
                None,
                get_request(port, CoreExpectBody::Text),
                CancellationToken::new(),
                CancellationToken::new(),
            )
            .await
            .unwrap();
            assert_eq!(response.status_code, 200);
        }
        server.abort();

        assert_eq!(accepts.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn fresh_client_per_request_opens_a_connection_each_time() {
        let accepts = Arc::new(AtomicUsize::new(0));
        let (port, server) = serve_keepalive(KEEPALIVE_OK, accepts.clone()).await;

        for _ in 0..2 {
            // None client: resolve_client builds (and drops) a client per call,
            // so the pool cannot carry over. This is the LL-13 keep-alive waste
            // the Dart handle pool eliminates by sharing one client.
            let response = execute(
                None,
                Some(ClientSettings::default()),
                get_request(port, CoreExpectBody::Text),
                CancellationToken::new(),
                CancellationToken::new(),
            )
            .await
            .unwrap();
            assert_eq!(response.status_code, 200);
        }
        server.abort();

        assert_eq!(accepts.load(Ordering::SeqCst), 2);
    }
}
