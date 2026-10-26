use crate::api::http::HttpResponseBody;
use rhttp_core::{CoreError, CoreErrorBody};
use std::fmt::Display;

#[derive(Clone, Debug)]
pub enum RhttpError {
    RhttpCancelError,
    RhttpTimeoutError,
    RhttpRedirectError,
    RhttpStatusCodeError(u16, Vec<(String, String)>, HttpResponseBody),
    RhttpInvalidCertificateError(String),
    RhttpConnectionError(String),
    RhttpUnknownError(String),
}

// Flutter Rust Bridge only supports anyhow, so we define string constants for the error messages.
pub(crate) const STREAM_CANCEL_ERROR: &str = "STREAM_CANCEL_ERROR";

impl Display for RhttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RhttpError::RhttpCancelError => write!(f, "RhttpCancelError"),
            RhttpError::RhttpTimeoutError => write!(f, "RhttpTimeoutError"),
            RhttpError::RhttpRedirectError => write!(f, "RhttpRedirectError"),
            RhttpError::RhttpStatusCodeError(i, _, _) => {
                write!(f, "RhttpStatusCodeError: {i}")
            }
            RhttpError::RhttpInvalidCertificateError(d) => {
                write!(f, "RhttpInvalidCertificateError: {d}")
            }
            RhttpError::RhttpConnectionError(e) => write!(f, "RhttpConnectionError: {e}"),
            RhttpError::RhttpUnknownError(e) => write!(f, "{}", e),
        }
    }
}

impl std::error::Error for RhttpError {}

impl From<CoreError> for RhttpError {
    fn from(error: CoreError) -> Self {
        match error {
            CoreError::Unknown(message) => RhttpError::RhttpUnknownError(message),
            CoreError::InvalidCertificate(message) => {
                RhttpError::RhttpInvalidCertificateError(message)
            }
            CoreError::Connection(message) => RhttpError::RhttpConnectionError(message),
            CoreError::Timeout => RhttpError::RhttpTimeoutError,
            CoreError::Redirect => RhttpError::RhttpRedirectError,
            CoreError::Cancelled => RhttpError::RhttpCancelError,
            CoreError::StatusCode(code, headers, body) => {
                RhttpError::RhttpStatusCodeError(code, headers, body.into())
            }
        }
    }
}

impl From<CoreErrorBody> for HttpResponseBody {
    fn from(body: CoreErrorBody) -> Self {
        match body {
            CoreErrorBody::Text(text) => HttpResponseBody::Text(text),
            CoreErrorBody::Bytes(bytes) => HttpResponseBody::Bytes(bytes),
            CoreErrorBody::Stream => HttpResponseBody::Stream,
        }
    }
}
