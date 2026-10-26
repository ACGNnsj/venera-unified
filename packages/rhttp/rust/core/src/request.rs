use crate::error::CoreError;
use futures_util::Stream;
use std::collections::HashMap;
use std::pin::Pin;

/// A host-provided byte stream. The FRB adapter feeds it from
/// `Dart2RustStreamReceiver`; a uniffi adapter can feed it from a callback
/// interface. Core code only sees a neutral stream.
pub type ByteStream = Pin<Box<dyn Stream<Item = Result<Vec<u8>, CoreError>> + Send + 'static>>;

pub enum CoreHeaders {
    Map(HashMap<String, String>),
    List(Vec<(String, String)>),
}

pub enum CoreBody {
    Text(String),
    Bytes(Vec<u8>),
    BytesStream,
    Form(HashMap<String, String>),
    Multipart(CoreMultipartPayload),
}

pub struct CoreMultipartPayload {
    pub parts: Vec<(String, CoreMultipartItem)>,
}

pub struct CoreMultipartItem {
    pub value: CoreMultipartValue,
    pub file_name: Option<String>,
    pub content_type: Option<String>,
}

pub enum CoreMultipartValue {
    Text(String),
    Bytes(Vec<u8>),
    File(String),
}

#[derive(Clone, Copy)]
pub enum CoreExpectBody {
    Text,
    Bytes,
    Stream,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CoreHttpVersion {
    Http09,
    Http10,
    Http11,
    Http2,
    Http3,
    Other,
}

pub struct CoreRequest {
    pub method: String,
    pub url: String,
    pub query: Option<Vec<(String, String)>>,
    pub headers: Option<CoreHeaders>,
    pub body: Option<CoreBody>,
    pub body_stream: Option<ByteStream>,
    pub expect_body: CoreExpectBody,
}

pub struct CoreResponse {
    pub remote_ip: Option<String>,
    pub headers: Vec<(String, String)>,
    pub version: CoreHttpVersion,
    pub status_code: u16,
    pub body: CoreResponseBody,
}

pub enum CoreResponseBody {
    Text(String),
    Bytes(Vec<u8>),
    Stream(ByteStream),
}
