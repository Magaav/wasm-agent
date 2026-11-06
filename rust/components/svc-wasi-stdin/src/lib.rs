//! Fixture for the WASI grant policy (`docs/WASI-INTERFACES.md`, tier B): `wasi:cli/stdin@0.3.0`.
//!
//! `read-via-stream` gives the guest its stdin as a `stream<u8>`; the fixture counts the bytes to the
//! end and reports `stdin bytes=<n>`. The host hands it a fixed pipe (never the node's own stdin), so
//! the number is the test's text length - a value the log then proves the grant carried.
//!
//! With no `stdin` grant the interface is not linked and the component is refused before it runs; the
//! runner reports `wasi_import_not_granted:wasi:cli/stdin@0.3.0` instead of handing it an empty pipe,
//! which would look like an EOF the guest could not tell from a granted-but-silent stdin.
wit_bindgen::generate!({ path: "../../../wit/kernel-v2", world: "wasi-probe-stdin", generate_all });

use std::time::Duration;
use wa::kernel::{lifecycle, log};
use wasi::cli::stdin;
use wasi::clocks::monotonic_clock;

struct Service;

fn line(text: &str) {
    log::write(log::Level::Info, "wasi-stdin", text);
}

impl exports::wa::kernel::service::Guest for Service {
    async fn run(_config: String) -> Result<(), String> {
        let (mut stream, errors) = stdin::read_via_stream();
        let mut bytes = 0usize;
        let mut head = Vec::new();
        while let Some(byte) = stream.next().await {
            bytes += 1;
            if head.len() < 32 {
                head.push(byte);
            }
            if bytes > 64 * 1024 {
                break;
            }
        }
        line(&format!("stdin bytes={bytes} head={:?}", String::from_utf8_lossy(&head).trim()));
        line(&format!("stdin read result={:?}", errors.await));
        lifecycle::report(lifecycle::Health::Ready, None);
        loop {
            if lifecycle::stopping() {
                line("stopping cleanly");
                return Ok(());
            }
            monotonic_clock::wait_for(Duration::from_millis(100).as_nanos() as u64).await;
        }
    }
}

export!(Service);
