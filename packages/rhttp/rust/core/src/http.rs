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
    use futures_util::StreamExt;
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
}
