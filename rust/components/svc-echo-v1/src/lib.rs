//! Fixture service on `wa:kernel@0.1` (the poll contract), kept as the compatibility fixture: the
//! host must keep running 0.1 components unchanged now that `wa:kernel@0.2` exists.
//!
//! What it proves, all through the registry lifecycle the gate drives (`services` tool):
//! heartbeat lines in the service log, a kv round trip inside its own namespace, one granted http
//! exchange (the address in `config.dial`), one refused one (the address in `config.refused`, which
//! prints the same `-13` the wasip1 fixture prints for EACCES), a clean stop when the supervisor
//! asks, and crash mode (a non-zero exit) for the restart path.
wit_bindgen::generate!({ path: "../../../wit/kernel", world: "service-component" });

use std::time::Duration;
use wa::kernel::types::Error as KError;
use wa::kernel::{http, kv, lifecycle, log};

struct Service;

impl exports::wa::kernel::service::Guest for Service {
    fn run(config: String) -> Result<(), String> {
        let config: serde_json::Value = serde_json::from_str(&config).unwrap_or_default();
        if config["crash"] == true {
            println!("crashing on purpose");
            std::thread::sleep(Duration::from_millis(200));
            std::process::exit(3);
        }
        console("heartbeat start");
        kv_round_trip();
        if let Some(url) = config["dial"].as_str() {
            dial(url);
        }
        if let Some(url) = config["refused"].as_str() {
            dial(url);
        }
        lifecycle::report(lifecycle::Health::Ready, None);
        loop {
            if lifecycle::stopping() {
                console("stopping cleanly");
                return Ok(());
            }
            console("heartbeat");
            std::thread::sleep(Duration::from_millis(300));
        }
    }
}

/// One line into the service log, through the kernel's log when it is imported and stdout
/// otherwise (the 0.1 fixture predates nothing here: both land in `<name>.service.log`).
fn console(line: &str) {
    log::write(log::Level::Info, "svc-echo-v1", line);
    println!("{line}");
}

/// put/get/scan/delete inside this component's own namespace (`storage` grant).
fn kv_round_trip() {
    let key = b"svc-echo/counter".to_vec();
    if let Err(error) = kv::set(&key, b"1") {
        console(&format!("kv unavailable {error:?}"));
        return;
    }
    let value = kv::get(&key).ok().flatten().unwrap_or_default();
    let page = kv::scan(b"svc-echo/", None, 8).unwrap_or_default();
    let _ = kv::delete(&key);
    console(&format!("kv ok value={} page={}", String::from_utf8_lossy(&value), page.len()));
}

/// One http exchange through the kernel, polled the way 0.1 requires.
fn dial(url: &str) {
    let request = http::Request { method: "GET".into(), url: url.into(), headers: vec![], body: vec![] };
    let pending = match http::Pending::start(&request) {
        Ok(pending) => pending,
        Err(KError::Refused(_)) => {
            console("refused -13 (grant)");
            return;
        }
        Err(error) => {
            console(&format!("dial failed {error:?}"));
            return;
        }
    };
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        match pending.poll() {
            Ok(response) => {
                console(&format!("dial ok status={} bytes={}", response.status, response.body.len()));
                return;
            }
            Err(KError::Again) if std::time::Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            Err(KError::Again) => {
                console("dial failed timeout");
                return;
            }
            Err(error) => {
                console(&format!("dial failed {error:?}"));
                return;
            }
        }
    }
}

export!(Service);
