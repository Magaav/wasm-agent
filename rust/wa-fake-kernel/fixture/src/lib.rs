//! Fixture service on `wa:kernel@0.2`, written for the fake kernel: every capability the fake
//! kernel can script, in the order a test can assert, and a `config` that decides which halves run.
//!
//! It is deliberately small and boring. What it proves is the *host*: that the in-memory kernel
//! answers the same WIT the node answers, that a grant it did not make is refused, that a record of
//! the run can be replayed, and that `wa dev` can swap a new build for an old one.
//!
//! Config (all optional):
//!
//! | key | effect |
//! | --- | --- |
//! | `dial` | one `http.send` for that URL (granted by the kernel's `net`, or refused by it) |
//! | `refused` | one `http.send` for a URL the kernel does not grant |
//! | `ws` | one websocket connect + send + receive for that URL |
//! | `speech` | one `speech.recognize`, its segments and its transcript |
//! | `secret` | one `credentials.get` for that name |
//! | `exit_after_ms` | return by itself after this long (with `tick_ms` heartbeats in between) |
//! | `tick_ms` | heartbeat period (default 20) |
//! | `crash` | exit non-zero at once, for the supervisor's restart path |
//! | `version` | printed in the log, so a swap can be seen in the log tail |
wit_bindgen::generate!({ path: "../../../wit/kernel-v2", world: "service-component", generate_all });

use std::time::Duration;
use wa::kernel::types::Error as KError;
use wa::kernel::{credentials, http, kv, lifecycle, log, speech, websocket};
use wasi::clocks::monotonic_clock;

struct Service;

impl exports::wa::kernel::service::Guest for Service {
    async fn run(config: String) -> Result<(), String> {
        let config: serde_json::Value = serde_json::from_str(&config).unwrap_or_default();
        if config["crash"] == true {
            line("crashing on purpose");
            std::process::exit(3);
        }
        line(&format!("start version={}", config["version"].as_str().unwrap_or("dev")));
        kv_round_trip().await;
        if let Some(name) = config["secret"].as_str() {
            check_secret(name);
        }
        if let Some(url) = config["dial"].as_str() {
            dial(url).await;
        }
        if let Some(url) = config["refused"].as_str() {
            dial(url).await;
        }
        if let Some(url) = config["ws"].as_str() {
            ws_echo(url).await;
        }
        if config["speech"] == true {
            transcribe().await;
        }
        lifecycle::report(lifecycle::Health::Ready, None);
        line("ready");
        let tick = Duration::from_millis(config["tick_ms"].as_u64().unwrap_or(20));
        let exit_after = config["exit_after_ms"].as_u64().unwrap_or(0);
        let began = monotonic_clock::now();
        loop {
            if lifecycle::stopping() {
                line("stopping cleanly");
                return Ok(());
            }
            if exit_after > 0 && monotonic_clock::now().saturating_sub(began) >= exit_after * 1_000_000 {
                line("returning after exit_after_ms");
                return Ok(());
            }
            line("heartbeat");
            wait(tick).await;
        }
    }
}

async fn wait(for_: Duration) {
    monotonic_clock::wait_for(for_.as_nanos() as u64).await;
}

fn line(text: &str) {
    log::write(log::Level::Info, "fake-kernel-fixture", text);
    println!("{text}");
}

/// put/get/scan/delete-prefix inside the component's own namespace (`storage` grant). The 0.2 calls
/// are async in shape; the host answers without suspending, so each await completes in one poll.
async fn kv_round_trip() {
    let key = b"fixture/counter".to_vec();
    if let Err(error) = kv::set(key.clone(), b"1".to_vec()).await {
        line(&format!("kv unavailable {error:?}"));
        return;
    }
    let value = kv::get(key.clone()).await.ok().flatten().unwrap_or_default();
    let page = kv::scan(b"fixture/".to_vec(), None, 8).await.unwrap_or_default();
    let _ = kv::delete(key).await;
    let removed = kv::delete_prefix(b"fixture/tmp/".to_vec()).await.unwrap_or(0);
    line(&format!("kv ok value={} page={} deleted={removed}", String::from_utf8_lossy(&value), page.len()));
}

/// A secret is readable by name and never logged: only its length is reported.
fn check_secret(name: &str) {
    match credentials::get(name) {
        Ok(value) => line(&format!("secret ok {} bytes", value.len())),
        Err(error) => line(&format!("secret refused {error:?}")),
    }
}

/// One suspendable http exchange; the body is a stream of chunks.
async fn dial(url: &str) {
    let request = http::Request { method: "GET".into(), url: url.into(), headers: vec![], body: vec![] };
    let response = match http::send(request).await {
        Ok(response) => response,
        Err(KError::Refused(_)) => {
            line("refused (grant)");
            return;
        }
        Err(error) => {
            line(&format!("dial failed {error:?}"));
            return;
        }
    };
    let status = response.status();
    let mut body = Vec::new();
    let mut stream = response.body();
    while let Some(chunk) = stream.next().await {
        body.extend_from_slice(&chunk);
    }
    line(&format!("dial ok status={status} bytes={} body={}", body.len(), String::from_utf8_lossy(&body)));
}

/// connect (awaitable), send (suspends), messages (a stream).
async fn ws_echo(url: &str) {
    let socket = match websocket::Socket::connect(url.to_string(), None).await {
        Ok(socket) => socket,
        Err(error) => {
            line(&format!("ws failed {error:?}"));
            return;
        }
    };
    if let Err(error) = socket.send(b"ping".to_vec()).await {
        line(&format!("ws send failed {error:?}"));
        socket.close(1000, "send failed".into());
        return;
    }
    let mut messages = socket.messages();
    let first = messages.next().await;
    line(&format!("ws ok {} bytes", first.map(|frame| frame.len()).unwrap_or(0)));
    socket.close(1000, "bye".into());
}

/// The recognizer's two halves: a segment stream and one result future.
async fn transcribe() {
    match speech::recognize(b"OggS-not-really-audio".to_vec(), "audio/ogg".to_string(), "pt".to_string()).await {
        Ok(recognition) => {
            let mut segments = recognition.segments();
            let transcript = recognition.transcript();
            let mut seen = 0usize;
            let mut first = String::new();
            while let Some(segment) = segments.next().await {
                seen += 1;
                if first.is_empty() {
                    first = segment.text;
                }
            }
            let outcome = transcript.await;
            line(&format!(
                "stt ok segments={seen} first={first} result={}",
                match outcome {
                    Ok(transcript) => format!("{} chars language={}", transcript.text.chars().count(), transcript.language),
                    Err(error) => format!("{error:?}"),
                }
            ));
        }
        Err(error) => line(&format!("stt failed {error:?}")),
    }
}

export!(Service);
