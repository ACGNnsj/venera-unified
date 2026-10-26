use flutter_rust_bridge::for_generated::anyhow;
use flutter_rust_bridge::{frb, DartFnFuture};
use futures_util::{future::Shared, FutureExt, StreamExt};
use rhttp_core::{
    ByteStream, CoreBody, CoreError, CoreExpectBody, CoreHeaders, CoreHttpVersion,
    CoreMultipartItem, CoreMultipartPayload, CoreMultipartValue, CoreRequest, CoreResponse,
    CoreResponseBody,
};
use std::collections::HashMap;
use std::sync::Mutex;
use tokio_util::sync::CancellationToken;

use crate::api::client::{ClientSettings, RequestClient};
use crate::api::error::RhttpError;
use crate::api::{error, stream};
use crate::frb_generated::{RustAutoOpaque, StreamSink};

pub struct HttpMethod {
    pub method: String,
}

pub enum HttpHeaders {
    Map(HashMap<String, String>),
    List(Vec<(String, String)>),
}

pub enum HttpBody {
    Text(String),
    Bytes(Vec<u8>),
    BytesStream,
    Form(HashMap<String, String>),
    Multipart(MultipartPayload),
}

pub struct MultipartPayload {
    pub parts: Vec<(String, MultipartItem)>,
    // https://github.com/seanmonstar/reqwest/issues/2374
    // pub boundary: Option<String>,
}

pub struct MultipartItem {
    pub value: MultipartValue,
    pub file_name: Option<String>,
    pub content_type: Option<String>,
}

pub enum MultipartValue {
    Text(String),
    Bytes(Vec<u8>),
    File(String),
}

#[derive(Clone, Copy)]
pub enum HttpVersionPref {
    Http10,
    Http11,
    Http2,
    Http3,
    All,
}

#[derive(Clone, Copy)]
pub enum HttpExpectBody {
    Text,
    Bytes,
}

pub enum HttpVersion {
    Http09,
    Http10,
    Http11,
    Http2,
    Http3,
    Other,
}

impl HttpVersion {
    fn from_core(version: CoreHttpVersion) -> HttpVersion {
        match version {
            CoreHttpVersion::Http09 => HttpVersion::Http09,
            CoreHttpVersion::Http10 => HttpVersion::Http10,
            CoreHttpVersion::Http11 => HttpVersion::Http11,
            CoreHttpVersion::Http2 => HttpVersion::Http2,
            CoreHttpVersion::Http3 => HttpVersion::Http3,
            CoreHttpVersion::Other => HttpVersion::Other,
        }
    }
}

pub struct HttpResponse {
    pub remote_ip: Option<String>,
    pub headers: Vec<(String, String)>,
    pub version: HttpVersion,
    pub status_code: u16,
    pub body: HttpResponseBody,
}

#[derive(Clone, Debug)]
pub enum HttpResponseBody {
    Text(String),
    Bytes(Vec<u8>),
    Stream,
}

// It must be async so that frb provides an async context.
pub async fn register_client(settings: ClientSettings) -> Result<RequestClient, RhttpError> {
    register_client_internal(settings)
}

#[frb(sync)]
pub fn register_client_sync(settings: ClientSettings) -> Result<RequestClient, RhttpError> {
    register_client_internal(settings)
}

fn register_client_internal(settings: ClientSettings) -> Result<RequestClient, RhttpError> {
    let client = RequestClient::new(settings)?;
    Ok(client)
}

pub fn cancel_running_requests(client: &RequestClient) {
    client.core.cancel_token.cancel();
}

pub async fn make_http_request(
    client: Option<RustAutoOpaque<RequestClient>>,
    settings: Option<ClientSettings>,
    method: HttpMethod,
    url: String,
    query: Option<Vec<(String, String)>>,
    headers: Option<HttpHeaders>,
    body: Option<HttpBody>,
    body_stream: Option<stream::Dart2RustStreamReceiver>,
    expect_body: HttpExpectBody,
    on_cancel_token: impl Fn(CancellationToken) -> DartFnFuture<()>,
    cancelable: bool,
) -> Result<HttpResponse, RhttpError> {
    let cancel_tokens = build_cancel_tokens(client.clone());

    if cancelable {
        on_cancel_token(cancel_tokens.request_cancel_token.clone()).await;
    }

    let request = CoreRequest {
        method: method.method,
        url,
        query,
        headers: headers.map(HttpHeaders::into_core),
        body: body.map(HttpBody::into_core),
        body_stream: body_stream.map(into_core_stream),
        expect_body: expect_body.into_core(),
    };

    rhttp_core::execute(
        client.map(|client| client.try_read().unwrap().core.clone()),
        settings.map(ClientSettings::into_core),
        request,
        cancel_tokens.request_cancel_token,
        cancel_tokens.client_cancel_token,
    )
    .await
    .map(HttpResponse::from_core)
    .map_err(RhttpError::from)
}

struct RequestCancelTokens {
    request_cancel_token: CancellationToken,
    client_cancel_token: CancellationToken,
}

fn build_cancel_tokens(client: Option<RustAutoOpaque<RequestClient>>) -> RequestCancelTokens {
    let client_cancel_token = match client {
        Some(client) => Some(client.try_read().unwrap().core.cancel_token.clone()),
        None => None,
    }
    .unwrap_or_else(CancellationToken::new);

    RequestCancelTokens {
        request_cancel_token: CancellationToken::new(),
        client_cancel_token,
    }
}

pub async fn make_http_request_receive_stream(
    client: Option<RustAutoOpaque<RequestClient>>,
    settings: Option<ClientSettings>,
    method: HttpMethod,
    url: String,
    query: Option<Vec<(String, String)>>,
    headers: Option<HttpHeaders>,
    body: Option<HttpBody>,
    body_stream: Option<stream::Dart2RustStreamReceiver>,
    stream_sink: StreamSink<Vec<u8>>,
    on_response: impl Fn(HttpResponse) -> DartFnFuture<()>,
    on_error: impl Fn(RhttpError) -> DartFnFuture<()>,
    on_cancel_token: impl Fn(CancellationToken) -> DartFnFuture<()>,
    cancelable: bool,
) {
    let cancel_tokens = build_cancel_tokens(client.clone());

    if cancelable {
        on_cancel_token(cancel_tokens.request_cancel_token.clone()).await;
    }

    // A Dart callback's receiver must survive cancellation of the request.
    // FRB 2.11.1 aborts if Dart delivers an acknowledgment to a dropped receiver.
    // Shared keeps each in-flight callback alive without spawning another task;
    // joining after select also makes native completion a callback-drain barrier.
    let callbacks = CallbackDrain::default();
    let on_response = |response| callbacks.track(on_response(response));
    let on_error = |error| callbacks.track(on_error(error));

    let request = CoreRequest {
        method: method.method,
        url,
        query,
        headers: headers.map(HttpHeaders::into_core),
        body: body.map(HttpBody::into_core),
        body_stream: body_stream.map(into_core_stream),
        expect_body: CoreExpectBody::Stream,
    };

    tokio::select! {
        _ = cancel_tokens.request_cancel_token.cancelled() => {
            let _ = stream_sink.add_error(anyhow::anyhow!(error::STREAM_CANCEL_ERROR));
            on_error(RhttpError::RhttpCancelError).await;
        },
        _ = cancel_tokens.client_cancel_token.cancelled() => {
            let _ = stream_sink.add_error(anyhow::anyhow!(error::STREAM_CANCEL_ERROR));
            on_error(RhttpError::RhttpCancelError).await;
        },
        result = rhttp_core::execute(
            client.map(|client| client.try_read().unwrap().core.clone()),
            settings.map(ClientSettings::into_core),
            request,
            cancel_tokens.request_cancel_token.clone(),
            cancel_tokens.client_cancel_token.clone(),
        ) => {
            match result {
                Ok(response) => {
                    let (http_response, stream) = split_stream_response(response);
                    on_response(http_response).await;

                    if let Some(mut stream) = stream {
                        loop {
                            tokio::select! {
                                _ = cancel_tokens.request_cancel_token.cancelled() => {
                                    let _ = stream_sink.add_error(anyhow::anyhow!(error::STREAM_CANCEL_ERROR));
                                    on_error(RhttpError::RhttpCancelError).await;
                                    break;
                                },
                                _ = cancel_tokens.client_cancel_token.cancelled() => {
                                    let _ = stream_sink.add_error(anyhow::anyhow!(error::STREAM_CANCEL_ERROR));
                                    on_error(RhttpError::RhttpCancelError).await;
                                    break;
                                },
                                chunk = stream.next() => {
                                    match chunk {
                                        Some(Ok(bytes)) => {
                                            if stream_sink.add(bytes).is_err() {
                                                break;
                                            }
                                        }
                                        Some(Err(error)) => {
                                            let _ = stream_sink.add_error(anyhow::anyhow!(error.to_string()));
                                            break;
                                        }
                                        None => break,
                                    }
                                }
                            }
                        }
                    }
                }
                Err(error) => {
                    on_error(RhttpError::from(error)).await;
                }
            }
        }
    }

    callbacks.join().await;
}

#[derive(Default)]
struct CallbackDrain {
    pending: Mutex<Vec<Shared<DartFnFuture<()>>>>,
}

impl CallbackDrain {
    fn track(&self, callback: DartFnFuture<()>) -> DartFnFuture<()> {
        let callback = callback.shared();
        self.pending.lock().unwrap().push(callback.clone());
        Box::pin(callback)
    }

    async fn join(&self) {
        // Call only after the request future has settled/dropped, so no callback
        // can be registered after taking the list. Never hold a lock over await.
        let callbacks = std::mem::take(&mut *self.pending.lock().unwrap());
        for callback in callbacks {
            callback.await;
        }
    }
}

#[cfg(test)]
mod callback_drain_tests {
    use super::CallbackDrain;
    use futures_util::{pin_mut, poll};
    use std::task::Poll;
    use tokio::sync::oneshot;

    #[tokio::test]
    async fn cancelled_request_keeps_callback_receiver_alive_until_ack() {
        let callbacks = CallbackDrain::default();
        let (ack, receiver) = oneshot::channel::<()>();
        {
            let request_callback = callbacks.track(Box::pin(async move {
                receiver.await.expect("Dart acknowledgment missing");
            }));
            pin_mut!(request_callback);
            assert!(matches!(poll!(request_callback), Poll::Pending));
            // Dropping this branch models tokio::select request cancellation.
        }
        let finishing = callbacks.join();
        pin_mut!(finishing);
        assert!(matches!(poll!(finishing.as_mut()), Poll::Pending));
        ack.send(())
            .expect("cancellation dropped the Dart receiver");
        finishing.await;
        assert!(callbacks.pending.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn native_return_waits_for_both_response_and_error_acknowledgments() {
        let callbacks = CallbackDrain::default();
        let (response_ack, response_receiver) = oneshot::channel::<()>();
        let (error_ack, error_receiver) = oneshot::channel::<()>();
        drop(callbacks.track(Box::pin(async move {
            response_receiver.await.unwrap();
        })));
        drop(callbacks.track(Box::pin(async move {
            error_receiver.await.unwrap();
        })));
        let finishing = callbacks.join();
        pin_mut!(finishing);
        assert!(matches!(poll!(finishing.as_mut()), Poll::Pending));
        response_ack.send(()).unwrap();
        assert!(matches!(poll!(finishing.as_mut()), Poll::Pending));
        error_ack.send(()).unwrap();
        finishing.await;
    }

    #[tokio::test]
    async fn acknowledged_callback_and_empty_drain_complete_normally() {
        let callbacks = CallbackDrain::default();
        callbacks.track(Box::pin(async {})).await;
        callbacks.join().await;
        callbacks.join().await;
    }
}

fn split_stream_response(response: CoreResponse) -> (HttpResponse, Option<ByteStream>) {
    let CoreResponse {
        remote_ip,
        headers,
        version,
        status_code,
        body,
    } = response;

    let (body, stream) = match body {
        CoreResponseBody::Text(text) => (HttpResponseBody::Text(text), None),
        CoreResponseBody::Bytes(bytes) => (HttpResponseBody::Bytes(bytes), None),
        CoreResponseBody::Stream(stream) => (HttpResponseBody::Stream, Some(stream)),
    };

    (
        HttpResponse {
            remote_ip,
            headers,
            version: HttpVersion::from_core(version),
            status_code,
            body,
        },
        stream,
    )
}

impl HttpResponse {
    fn from_core(response: CoreResponse) -> HttpResponse {
        let (response, _) = split_stream_response(response);
        response
    }
}

impl HttpHeaders {
    fn into_core(self) -> CoreHeaders {
        match self {
            HttpHeaders::Map(map) => CoreHeaders::Map(map),
            HttpHeaders::List(list) => CoreHeaders::List(list),
        }
    }
}

impl HttpBody {
    fn into_core(self) -> CoreBody {
        match self {
            HttpBody::Text(text) => CoreBody::Text(text),
            HttpBody::Bytes(bytes) => CoreBody::Bytes(bytes),
            HttpBody::BytesStream => CoreBody::BytesStream,
            HttpBody::Form(form) => CoreBody::Form(form),
            HttpBody::Multipart(payload) => CoreBody::Multipart(payload.into_core()),
        }
    }
}

impl MultipartPayload {
    fn into_core(self) -> CoreMultipartPayload {
        CoreMultipartPayload {
            parts: self
                .parts
                .into_iter()
                .map(|(name, item)| (name, item.into_core()))
                .collect(),
        }
    }
}

impl MultipartItem {
    fn into_core(self) -> CoreMultipartItem {
        CoreMultipartItem {
            value: self.value.into_core(),
            file_name: self.file_name,
            content_type: self.content_type,
        }
    }
}

impl MultipartValue {
    fn into_core(self) -> CoreMultipartValue {
        match self {
            MultipartValue::Text(text) => CoreMultipartValue::Text(text),
            MultipartValue::Bytes(bytes) => CoreMultipartValue::Bytes(bytes),
            MultipartValue::File(path) => CoreMultipartValue::File(path),
        }
    }
}

impl HttpExpectBody {
    fn into_core(self) -> CoreExpectBody {
        match self {
            HttpExpectBody::Text => CoreExpectBody::Text,
            HttpExpectBody::Bytes => CoreExpectBody::Bytes,
        }
    }
}

fn into_core_stream(receiver: stream::Dart2RustStreamReceiver) -> ByteStream {
    Box::pin(
        receiver
            .receiver
            .map(|chunk| Ok::<Vec<u8>, CoreError>(chunk)),
    )
}

pub fn cancel_request(token: &CancellationToken) {
    token.cancel();
}
