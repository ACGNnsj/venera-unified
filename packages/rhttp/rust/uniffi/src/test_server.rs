//! A capture-once HTTP server for the request-shape tests.
//!
//! Upload assertions have to look at the bytes the transport actually put on the
//! wire — form encoding, multipart boundaries, chunked framing — so this server
//! reads one complete request, frames it, hands it to the test, and answers
//! `200 OK` with the body `ok`.

use std::collections::HashMap;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;

pub struct CapturedRequest {
    pub method: String,
    /// Path plus query string, as sent on the request line.
    pub target: String,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

impl CapturedRequest {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .get(&name.to_ascii_lowercase())
            .map(String::as_str)
    }

    pub fn body_text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
}

/// Accept exactly one request, capture it, and answer `200 ok`.
pub async fn capture_one() -> (u16, oneshot::Receiver<CapturedRequest>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind a loopback listener");
    let port = listener
        .local_addr()
        .expect("read the listener address")
        .port();
    let (tx, rx) = oneshot::channel();

    tokio::spawn(async move {
        let (socket, _) = listener.accept().await.expect("accept one connection");
        let mut reader = Reader::new(socket);
        let request = read_request(&mut reader).await;
        reader
            .socket
            .write_all(
                b"HTTP/1.1 200 OK\r\n\
                  Content-Length: 2\r\n\
                  Connection: close\r\n\r\nok",
            )
            .await
            .expect("write the response");
        reader.socket.flush().await.expect("flush the response");
        let _ = tx.send(request);
    });

    (port, rx)
}

struct Reader {
    socket: TcpStream,
    buffer: Vec<u8>,
}

impl Reader {
    fn new(socket: TcpStream) -> Self {
        Self {
            socket,
            buffer: Vec::new(),
        }
    }

    /// Pull more bytes into the buffer. Returns false at end of stream.
    async fn fill(&mut self) -> bool {
        let mut chunk = [0u8; 8192];
        match self.socket.read(&mut chunk).await {
            Ok(0) | Err(_) => false,
            Ok(read) => {
                self.buffer.extend_from_slice(&chunk[..read]);
                true
            }
        }
    }

    /// Offset of `needle` in the buffer, reading until it shows up.
    async fn find(&mut self, needle: &[u8]) -> Option<usize> {
        loop {
            if let Some(position) = find_bytes(&self.buffer, needle) {
                return Some(position);
            }
            if !self.fill().await {
                return None;
            }
        }
    }

    async fn take(&mut self, count: usize) -> Vec<u8> {
        while self.buffer.len() < count {
            if !self.fill().await {
                break;
            }
        }
        let available = count.min(self.buffer.len());
        self.buffer.drain(..available).collect()
    }

    async fn take_line(&mut self) -> String {
        let end = self.find(b"\r\n").await.expect("a CRLF-terminated line");
        let line: Vec<u8> = self.buffer.drain(..end).collect();
        self.buffer.drain(..2);
        String::from_utf8_lossy(&line).into_owned()
    }
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

async fn read_request(reader: &mut Reader) -> CapturedRequest {
    let head_end = reader
        .find(b"\r\n\r\n")
        .await
        .expect("a request head terminated by an empty line");
    let head: Vec<u8> = reader.buffer.drain(..head_end).collect();
    reader.buffer.drain(..4);

    let head = String::from_utf8_lossy(&head).into_owned();
    let mut lines = head.split("\r\n");
    let request_line = lines.next().expect("a request line");
    let mut parts = request_line.split(' ');
    let method = parts.next().unwrap_or_default().to_string();
    let target = parts.next().unwrap_or_default().to_string();

    let mut headers = HashMap::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_string());
        }
    }

    let chunked = headers
        .get("transfer-encoding")
        .is_some_and(|value| value.to_ascii_lowercase().contains("chunked"));
    let body = if chunked {
        read_chunked(reader).await
    } else {
        let length = headers
            .get("content-length")
            .and_then(|value| value.parse::<usize>().ok())
            .unwrap_or(0);
        reader.take(length).await
    };

    CapturedRequest {
        method,
        target,
        headers,
        body,
    }
}

/// Multipart file parts are streamed by reqwest, so the request arrives with
/// `Transfer-Encoding: chunked` and the test has to unframe it.
async fn read_chunked(reader: &mut Reader) -> Vec<u8> {
    let mut body = Vec::new();
    loop {
        let line = reader.take_line().await;
        let size_text = line.split(';').next().unwrap_or("0").trim();
        let size = usize::from_str_radix(size_text, 16).expect("a hexadecimal chunk size");
        if size == 0 {
            break;
        }
        body.extend_from_slice(&reader.take(size).await);
        reader.take(2).await;
    }
    // The trailer section is irrelevant to every assertion here.
    body
}
