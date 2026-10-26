use std::fmt::{Display, Formatter};

/// Body carried by a status-code error. `Stream` is only a marker: the
/// adapter must not try to read a body that the caller did not request.
#[derive(Clone, Debug)]
pub enum CoreErrorBody {
    Text(String),
    Bytes(Vec<u8>),
    Stream,
}

/// UI-neutral error type for the rhttp core.
///
/// The FRB adapter converts this into its Dart-visible `RhttpError`; a future
/// uniffi adapter converts it into its own error enum.
#[derive(Clone, Debug)]
pub enum CoreError {
    Unknown(String),
    InvalidCertificate(String),
    Connection(String),
    Timeout,
    Redirect,
    StatusCode(u16, Vec<(String, String)>, CoreErrorBody),
    Cancelled,
}

impl Display for CoreError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            CoreError::Unknown(message) => write!(f, "{message}"),
            CoreError::InvalidCertificate(message) => {
                write!(f, "CoreInvalidCertificate: {message}")
            }
            CoreError::Connection(message) => write!(f, "CoreConnection: {message}"),
            CoreError::Timeout => write!(f, "CoreTimeout"),
            CoreError::Redirect => write!(f, "CoreRedirect"),
            CoreError::StatusCode(code, _, _) => write!(f, "CoreStatusCode: {code}"),
            CoreError::Cancelled => write!(f, "CoreCancelled"),
        }
    }
}

impl std::error::Error for CoreError {}
