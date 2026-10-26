//! Throughput probe over loopback: the same `rhttp-core` transport, read
//! through two different call paths.
//!
//! This is a measurement, not a functional test. It exists to answer one
//! question from ticket 06: what does the uniffi pull API cost on top of the
//! transport? Run it with
//!
//! ```text
//! cargo test -p rhttp-uniffi --release --test throughput -- --ignored --nocapture
//! ```
//!
//! Scope, stated plainly: both paths live in this process. The numbers show
//! what the uniffi layer adds (channel hop + per-chunk copy), *not* an
//! end-to-end comparison against the Flutter binding, which would need a Dart
//! or Kotlin host to be meaningful.
//!
//! Design note: loopback throughput on this machine moves by ±15% between
//! runs, which is far larger than the per-chunk cost being measured. A plain
//! core-vs-uniffi ratio therefore cannot resolve anything, so every round
//! measures the bare core twice and the uniffi path once. The two core numbers
//! are the control: unless the uniffi ratio leaves the band they span, the
//! binding cost is below this measurement's resolution.

use std::time::{Duration, Instant};

use rhttp_core::{
    build_client, execute, next_chunk, ClientSettings, CoreExpectBody, CoreRequest,
    CoreResponseBody,
};
use rhttp_uniffi::{default_client_options, RhttpClient};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;

/// Body size per round. Large enough that per-transfer setup does not dominate,
/// small enough to keep the whole run under a few seconds.
const BODY_BYTES: usize = 64 * 1024 * 1024;
/// Write size. Matches the 64 KiB chunks a server typically hands to hyper.
const CHUNK_BYTES: usize = 64 * 1024;
/// Rounds per configuration. Loopback numbers are noisy, so the median is
/// reported instead of the best: a best-of run hides how much the machine
/// wobbles.
const ROUNDS: usize = 5;

/// Serve exactly one connection with a fixed-length body, as fast as the socket
/// accepts it.
async fn spawn_server() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("local addr").port();

    tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.expect("accept");
        let mut request_head = [0u8; 2048];
        let _ = socket.read(&mut request_head).await;

        let head = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {BODY_BYTES}\r\n\
             Content-Type: application/octet-stream\r\n\r\n"
        );
        socket.write_all(head.as_bytes()).await.expect("head");

        let chunk = vec![0x5au8; CHUNK_BYTES];
        let mut sent = 0;
        while sent < BODY_BYTES {
            socket.write_all(&chunk).await.expect("body");
            sent += CHUNK_BYTES;
        }
        let _ = socket.shutdown().await;
    });

    format!("http://127.0.0.1:{port}/")
}

/// Read the whole body straight out of `rhttp-core`: the cheapest honest path,
/// with no binding layer in the middle.
async fn through_core(url: &str) -> (usize, Duration) {
    let request = CoreRequest {
        method: "GET".to_string(),
        url: url.to_string(),
        query: None,
        headers: None,
        body: None,
        body_stream: None,
        expect_body: CoreExpectBody::Stream,
    };

    let client = build_client(ClientSettings::default()).expect("client");
    let cancel = CancellationToken::new();

    let started = Instant::now();
    let response = execute(
        Some(client),
        Some(ClientSettings::default()),
        request,
        cancel.clone(),
        cancel,
    )
    .await
    .expect("execute");

    let mut body = match response.body {
        CoreResponseBody::Stream(stream) => stream,
        _ => panic!("expected a streamed body"),
    };

    let mut total = 0;
    while let Some(chunk) = next_chunk(&mut body).await {
        total += chunk.expect("chunk").len();
    }
    (total, started.elapsed())
}

/// Read the whole body through the exported uniffi surface, which is what a
/// Kotlin or Swift host would see.
async fn through_uniffi(url: &str) -> (usize, Duration) {
    let client = RhttpClient::new(default_client_options()).expect("client");

    let started = Instant::now();
    let handle = client.stream_get(url.to_string()).await.expect("open");
    let mut total = 0;
    while let Some(chunk) = handle.next_chunk().await.expect("chunk") {
        total += chunk.len();
    }
    (total, started.elapsed())
}

fn mib_per_second(bytes: usize, elapsed: Duration) -> f64 {
    (bytes as f64 / (1024.0 * 1024.0)) / elapsed.as_secs_f64()
}

fn median(values: &mut [f64]) -> f64 {
    values.sort_by(f64::total_cmp);
    values[values.len() / 2]
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "measurement, not an assertion: moves ~1 GiB; run with --release --ignored"]
async fn uniffi_pull_path_costs_nothing_measurable() {
    let mut rounds = Vec::with_capacity(ROUNDS);

    for round in 0..ROUNDS {
        let (first_bytes, first_elapsed) = through_core(&spawn_server().await).await;
        let (pull_bytes, pull_elapsed) = through_uniffi(&spawn_server().await).await;
        let (second_bytes, second_elapsed) = through_core(&spawn_server().await).await;

        assert_eq!(
            first_bytes, BODY_BYTES,
            "round {round}: first core truncated"
        );
        assert_eq!(
            pull_bytes, BODY_BYTES,
            "round {round}: uniffi path truncated"
        );
        assert_eq!(
            second_bytes, BODY_BYTES,
            "round {round}: second core truncated"
        );

        rounds.push((
            mib_per_second(first_bytes, first_elapsed),
            mib_per_second(pull_bytes, pull_elapsed),
            mib_per_second(second_bytes, second_elapsed),
        ));
    }

    for (index, (core, pull, control)) in rounds.iter().enumerate() {
        println!(
            "round {}: core {core:7.1}, uniffi {pull:7.1}, core again {control:7.1} MiB/s",
            index + 1
        );
    }

    let mut cores: Vec<f64> = rounds.iter().map(|(core, _, _)| *core).collect();
    let mut pulls: Vec<f64> = rounds.iter().map(|(_, pull, _)| *pull).collect();
    let mut controls: Vec<f64> = rounds.iter().map(|(_, _, control)| *control).collect();

    let median_core = median(&mut cores);
    let median_pull = median(&mut pulls);
    let median_control = median(&mut controls);

    println!("--- rhttp throughput over loopback ---");
    println!(
        "body {} MiB in {} chunks of {} KiB, median of {ROUNDS}",
        BODY_BYTES / (1024 * 1024),
        BODY_BYTES / CHUNK_BYTES,
        CHUNK_BYTES / 1024
    );
    println!("core (no binding) : {median_core:8.1} MiB/s");
    println!("uniffi pull       : {median_pull:8.1} MiB/s");
    println!("core again        : {median_control:8.1} MiB/s (control)");
    println!(
        "control drift     : {:8.1}%  (second core vs first, no binding changed)",
        (median_control / median_core - 1.0) * 100.0
    );
    println!(
        "uniffi vs core    : {:8.1}%  (binding layer's share)",
        (median_pull / median_core - 1.0) * 100.0
    );
    println!(
        "reading: if the uniffi figure sits inside the control drift, the binding\n\
         cost is below this probe's resolution and should be reported as such."
    );
}
