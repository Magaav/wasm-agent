//! Fixture service on `wa:kernel@0.2` (WASI 0.3, native async): the same contract as the 0.1
//! fixture (`svc-echo-v1`), with the waiting done by the runtime.
//!
//! Every slow thing the 0.1 fixture polled is awaited here: the heartbeat timer is
//! `wasi:clocks/monotonic-clock@0.3.0.wait-for`, an http exchange is one `http.send`, the websocket
//! echo reads the inbound `stream<list<u8>>` and awaits each `send`. Nothing loops on `poll`, and
//! nothing sleeps on a thread.
//!
//! It is also what the host tests use to prove the 0.2 runner end to end: heartbeat lines in the
//! log, a kv round trip, a granted and a refused http dial, a websocket echo over the stream, a
//! clean stop when the supervisor asks, and crash mode (a non-zero exit) for the restart path.
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
            // A component's exit goes through wasi:cli/exit, whose status is a `result` (ok/err):
            // WASI has no exit codes, so the supervisor reports exit_1 here where the wasip1
            // fixture reports exit_3. What it proves is the same: a non-zero exit is restarted.
            std::process::exit(3);
        }
        line("heartbeat start");
        kv_round_trip().await;
        check_credentials(&config);
        if let Some(url) = config["dial"].as_str() {
            dial(url).await;
        }
        if let Some(url) = config["refused"].as_str() {
            dial(url).await;
        }
        if let Some(url) = config["ws"].as_str() {
            ws_echo(url).await;
        }
        if config["stt"] == true {
            speech_probe().await;
        }
        lifecycle::report(lifecycle::Health::Ready, None);
        // The 0.1 fixture slept a thread; here the task parks in the runtime and the supervisor can
        // still stop it (the stop flag is read between ticks, and the epoch traps after the grace).
        let tick = Duration::from_millis(config["tick_ms"].as_u64().unwrap_or(300));
        loop {
            if lifecycle::stopping() {
                line("stopping cleanly");
                return Ok(());
            }
            line("heartbeat");
            wait(tick).await;
        }
    }
}

/// `wasi:clocks/monotonic-clock@0.3.0.wait-for`: the 0.2 replacement for a sleeping thread or a
/// polled timer. The guest task suspends; the runtime resumes it.
async fn wait(for_: Duration) {
    monotonic_clock::wait_for(for_.as_nanos() as u64).await;
}

/// One line into the service log, through the kernel's log (the same file stdout goes to).
fn line(text: &str) {
    log::write(log::Level::Info, "svc-echo", text);
    println!("{text}");
}

/// put/get/scan/delete inside this component's own namespace (`storage` grant). The 0.2 calls are
/// async in shape; the host answers without suspending, so each await completes in one poll.
async fn kv_round_trip() {
    let key = b"svc-echo/counter".to_vec();
    if let Err(error) = kv::set(key.clone(), b"1".to_vec()).await {
        line(&format!("kv unavailable {error:?}"));
        return;
    }
    let value = kv::get(key.clone()).await.ok().flatten().unwrap_or_default();
    let page = kv::scan(b"svc-echo/".to_vec(), None, 8).await.unwrap_or_default();
    let _ = kv::delete(key).await;
    line(&format!("kv ok value={} page={}", String::from_utf8_lossy(&value), page.len()));
}

/// `file_env` secrets are readable only by name, and never logged.
fn check_credentials(config: &serde_json::Value) {
    let Some(name) = config["secret"].as_str() else { return };
    match credentials::get(name) {
        Ok(value) => line(&format!("secret ok {} bytes", value.len())),
        Err(error) => line(&format!("secret refused {error:?}")),
    }
}

/// One suspendable http exchange: the body arrives as a stream, chunk by chunk.
async fn dial(url: &str) {
    let request = http::Request { method: "GET".into(), url: url.into(), headers: vec![], body: vec![] };
    let response = match http::send(request).await {
        Ok(response) => response,
        Err(KError::Refused(_)) => {
            line("refused -13 (grant)");
            return;
        }
        Err(error) => {
            line(&format!("dial failed {error:?}"));
            return;
        }
    };
    let mut body = Vec::new();
    let mut chunks = 0;
    let mut stream = response.body();
    while let Some(chunk) = stream.next().await {
        chunks += 1;
        body.extend_from_slice(&chunk);
    }
    line(&format!("dial ok status={} bytes={} chunks={}", response.status(), body.len(), chunks));
}

/// A websocket echo: `connect` is awaitable, the inbound frames are a stream, `send` suspends.
async fn ws_echo(url: &str) {
    let socket = match websocket::Socket::connect(url.to_string(), None).await {
        Ok(socket) => socket,
        Err(error) => {
            line(&format!("ws failed {error:?}"));
            return;
        }
    };
    let frame = b"ping".to_vec();
    if let Err(error) = socket.send(frame).await {
        line(&format!("ws send failed {error:?}"));
        socket.close(1000, "send failed".into());
        return;
    }
    let mut frames = socket.messages();
    match frames.next().await {
        Some(reply) => line(&format!("echo ok {} bytes", reply.len())),
        None => line("echo failed (stream ended)"),
    }
    socket.close(1000, "bye".into());
}

/// The recognizer without audio worth transcribing: proves the shape (a segment stream plus one
/// result future) and the grant, without needing the node's worker to have a model.
async fn speech_probe() {
    match speech::recognize(Vec::new(), "audio/ogg".to_string(), "pt".to_string()).await {
        Ok(recognition) => {
            let mut segments = recognition.segments();
            let outcome = recognition.transcript();
            let first = segments.next().await;
            let transcript = outcome.await;
            line(&format!(
                "speech ok segments={} result={}",
                first.is_some() as u8,
                match transcript {
                    Ok(t) => format!("{} chars", t.text.chars().count()),
                    Err(error) => format!("{error:?}"),
                }
            ));
        }
        Err(error) => line(&format!("speech refused {error:?}")),
    }
}

export!(Service);
