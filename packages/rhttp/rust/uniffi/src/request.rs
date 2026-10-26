//! Request-side types shared by the buffered and the streaming entry points.
//!
//! The core crate speaks plain Rust structures; uniffi needs named records and
//! enums per host language, so this module is the single place where a host
//! request is mirrored. Bodies are limited to the variants that need no host
//! callback: text, bytes, form fields, and multipart parts. Streaming *uploads*
//! (`CoreBody::BytesStream`) stay unimplemented here — pushing host bytes into
//! Rust needs a callback interface with its own backpressure contract, and no
//! consumer needs it yet.

use rhttp_core::{
    CoreBody, CoreExpectBody, CoreHeaders, CoreMultipartItem, CoreMultipartPayload,
    CoreMultipartValue, CoreRequest,
};

/// A name/value pair: a header, a query parameter, or a form field.
#[derive(Clone, Debug, uniffi::Record)]
pub struct RhttpHeader {
    pub name: String,
    pub value: String,
}

/// A URL query parameter or a form field.
///
/// Kept separate from [`RhttpHeader`] even though the shape is identical: hosts
/// get a name that says what it is, and the two never mix at a call site.
#[derive(Clone, Debug, uniffi::Record)]
pub struct RhttpField {
    pub name: String,
    pub value: String,
}

/// Where one multipart part's bytes come from.
#[derive(Clone, Debug, uniffi::Enum)]
pub enum MultipartValue {
    Text {
        text: String,
    },
    Bytes {
        bytes: Vec<u8>,
    },
    /// Path on the host filesystem. Read lazily while the request is sent, so a
    /// large file is never staged in memory here.
    File {
        path: String,
    },
}

/// One part of a `multipart/form-data` body.
#[derive(Clone, Debug, uniffi::Record)]
pub struct MultipartPart {
    pub name: String,
    pub value: MultipartValue,
    /// `filename="..."` in the part's `Content-Disposition`.
    pub file_name: Option<String>,
    /// The part's `Content-Type`. Left to the transport when null.
    pub content_type: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct MultipartPayload {
    pub parts: Vec<MultipartPart>,
}

/// The body of a request built by the host.
#[derive(Clone, Debug, uniffi::Enum)]
pub enum RequestBody {
    Text {
        text: String,
    },
    Bytes {
        bytes: Vec<u8>,
    },
    /// `application/x-www-form-urlencoded`.
    Form {
        fields: Vec<RhttpField>,
    },
    /// `multipart/form-data`.
    Multipart {
        payload: MultipartPayload,
    },
}

/// Everything a host needs to describe one HTTP request.
#[derive(Clone, Debug, uniffi::Record)]
pub struct HttpRequest {
    pub url: String,
    /// Defaults to `GET` when null. A request with a body normally wants
    /// `POST`, `PUT`, or `PATCH` set explicitly.
    pub method: Option<String>,
    pub headers: Vec<RhttpHeader>,
    pub query: Vec<RhttpField>,
    pub body: Option<RequestBody>,
}

impl HttpRequest {
    /// A plain `GET` for the URL conveniences (`fetchText`, `streamGet`, …).
    pub(crate) fn get(url: String) -> Self {
        Self {
            url,
            method: None,
            headers: Vec::new(),
            query: Vec::new(),
            body: None,
        }
    }

    pub(crate) fn into_core(self, expect_body: CoreExpectBody) -> CoreRequest {
        CoreRequest {
            method: self.method.unwrap_or_else(|| "GET".to_string()),
            url: self.url,
            query: list_or_none(
                self.query
                    .into_iter()
                    .map(|field| (field.name, field.value))
                    .collect(),
            ),
            headers: list_or_none(
                self.headers
                    .into_iter()
                    .map(|header| (header.name, header.value))
                    .collect(),
            )
            .map(CoreHeaders::List),
            body: self.body.map(RequestBody::into_core),
            body_stream: None,
            expect_body,
        }
    }
}

/// Empty collections become `None` so the transport does not send an empty
/// query string or an empty header list.
fn list_or_none<T>(items: Vec<T>) -> Option<Vec<T>> {
    if items.is_empty() {
        None
    } else {
        Some(items)
    }
}

impl RequestBody {
    fn into_core(self) -> CoreBody {
        match self {
            RequestBody::Text { text } => CoreBody::Text(text),
            RequestBody::Bytes { bytes } => CoreBody::Bytes(bytes),
            RequestBody::Form { fields } => CoreBody::Form(
                fields
                    .into_iter()
                    .map(|field| (field.name, field.value))
                    .collect(),
            ),
            RequestBody::Multipart { payload } => CoreBody::Multipart(CoreMultipartPayload {
                parts: payload
                    .parts
                    .into_iter()
                    .map(MultipartPart::into_core)
                    .collect(),
            }),
        }
    }
}

impl MultipartPart {
    fn into_core(self) -> (String, CoreMultipartItem) {
        let MultipartPart {
            name,
            value,
            file_name,
            content_type,
        } = self;
        (
            name,
            CoreMultipartItem {
                value: match value {
                    MultipartValue::Text { text } => CoreMultipartValue::Text(text),
                    MultipartValue::Bytes { bytes } => CoreMultipartValue::Bytes(bytes),
                    MultipartValue::File { path } => CoreMultipartValue::File(path),
                },
                file_name,
                content_type,
            },
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn header(name: &str, value: &str) -> RhttpHeader {
        RhttpHeader {
            name: name.to_string(),
            value: value.to_string(),
        }
    }

    fn field(name: &str, value: &str) -> RhttpField {
        RhttpField {
            name: name.to_string(),
            value: value.to_string(),
        }
    }

    fn request(body: Option<RequestBody>) -> CoreRequest {
        HttpRequest {
            url: "http://example.invalid/".to_string(),
            method: Some("POST".to_string()),
            headers: vec![header("x-test", "1")],
            query: vec![field("q", "a b")],
            body,
        }
        .into_core(CoreExpectBody::Bytes)
    }

    #[test]
    fn method_and_url_survive_the_mapping() {
        let mapped = request(None);
        assert_eq!(mapped.method, "POST");
        assert_eq!(mapped.url, "http://example.invalid/");
    }

    #[test]
    fn a_missing_method_becomes_get() {
        let mapped =
            HttpRequest::get("http://example.invalid/".to_string()).into_core(CoreExpectBody::Text);
        assert_eq!(mapped.method, "GET");
    }

    #[test]
    fn headers_and_query_keep_their_pairs() {
        let mapped = request(None);
        match mapped.headers {
            Some(CoreHeaders::List(pairs)) => {
                assert_eq!(pairs, vec![("x-test".to_string(), "1".to_string())])
            }
            _ => panic!("expected a header list"),
        }
        assert_eq!(
            mapped.query,
            Some(vec![("q".to_string(), "a b".to_string())])
        );
    }

    #[test]
    fn empty_headers_and_query_stay_none() {
        let mapped =
            HttpRequest::get("http://example.invalid/".to_string()).into_core(CoreExpectBody::Text);
        assert!(mapped.headers.is_none());
        assert!(mapped.query.is_none());
        assert!(mapped.body.is_none());
    }

    #[test]
    fn every_body_variant_reaches_the_core_type() {
        match request(Some(RequestBody::Text {
            text: "hello".to_string(),
        }))
        .body
        {
            Some(CoreBody::Text(text)) => assert_eq!(text, "hello"),
            _ => panic!("expected a text body"),
        }

        match request(Some(RequestBody::Bytes {
            bytes: vec![0, 159, 146, 150],
        }))
        .body
        {
            Some(CoreBody::Bytes(bytes)) => assert_eq!(bytes, vec![0, 159, 146, 150]),
            _ => panic!("expected a byte body"),
        }

        match request(Some(RequestBody::Form {
            fields: vec![field("a", "1"), field("b", "two words")],
        }))
        .body
        {
            Some(CoreBody::Form(fields)) => {
                assert_eq!(fields.get("a").map(String::as_str), Some("1"));
                assert_eq!(fields.get("b").map(String::as_str), Some("two words"));
            }
            _ => panic!("expected a form body"),
        }
    }

    #[test]
    fn multipart_parts_keep_name_value_and_metadata() {
        let mapped = request(Some(RequestBody::Multipart {
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
                        name: "image".to_string(),
                        value: MultipartValue::File {
                            path: "C:/tmp/cover.png".to_string(),
                        },
                        file_name: Some("cover.png".to_string()),
                        content_type: Some("image/png".to_string()),
                    },
                ],
            },
        }));

        let parts = match mapped.body {
            Some(CoreBody::Multipart(payload)) => payload.parts,
            _ => panic!("expected a multipart body"),
        };
        assert_eq!(parts.len(), 2);

        let (title_name, title) = &parts[0];
        assert_eq!(title_name, "title");
        assert!(matches!(&title.value, CoreMultipartValue::Text(text) if text == "cover"));
        assert!(title.file_name.is_none());

        let (image_name, image) = &parts[1];
        assert_eq!(image_name, "image");
        assert!(
            matches!(&image.value, CoreMultipartValue::File(path) if path == "C:/tmp/cover.png")
        );
        assert_eq!(image.file_name.as_deref(), Some("cover.png"));
        assert_eq!(image.content_type.as_deref(), Some("image/png"));
    }
}
