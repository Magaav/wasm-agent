//! Fixture for the WASI grant policy (`docs/WASI-INTERFACES.md`, tier B): the keyvalue/config shape.
//!
//! `wa:kernel/keyvalue` is the `wasi:keyvalue` proposal's shape (get/set/delete/exists/list-keys)
//! served over **this component's own kv namespace**, so what it proves is that the WASI-shaped store
//! and `wa:kernel/kv` are one key space with one set of policy rules (`kv.read`/`kv.write`).
//! `wa:kernel/config` is the read-only view of the non-secret config the operator granted; its reads
//! are policy-checked as `config.read`.
//!
//! Reported in the log:
//!   * `kv set ok`, `kv get=<value>`, `kv exists=true`, `kv keys=[...]`, `kv delete ok` - the round
//!     trip, all under one namespace.
//!   * `kv refused=<error>` when a rule denies the key (the test writes a policy that allows one
//!     prefix and the fixture writes outside it).
//!   * `config get=<value>` and `config keys=[...]` - the granted configuration, never the node's own.
wit_bindgen::generate!({ path: "../../../wit/kernel-v2", world: "wasi-probe-kv", generate_all });

use std::time::Duration;
use wa::kernel::types::Error as KError;
use wa::kernel::{config, keyvalue, lifecycle, log};
use wasi::clocks::monotonic_clock;

struct Service;

fn line(text: &str) {
    log::write(log::Level::Info, "wasi-kv", text);
}

fn reason(error: KError) -> String {
    match error {
        KError::Refused(why) => format!("refused({why})"),
        KError::Again => "again".into(),
        KError::Closed => "closed".into(),
        KError::Failed(why) => format!("failed({why})"),
    }
}

impl exports::wa::kernel::service::Guest for Service {
    async fn run(config_text: String) -> Result<(), String> {
        match keyvalue::set("probe/key".to_string(), b"value".to_vec()).await {
            Ok(()) => line("kv set ok"),
            Err(error) => line(&format!("kv refused set={}", reason(error))),
        }
        match keyvalue::get("probe/key".to_string()).await {
            Ok(Some(value)) => line(&format!("kv get={}", String::from_utf8_lossy(&value))),
            Ok(None) => line("kv get=none"),
            Err(error) => line(&format!("kv refused get={}", reason(error))),
        }
        match keyvalue::exists("probe/key".to_string()).await {
            Ok(found) => line(&format!("kv exists={found}")),
            Err(error) => line(&format!("kv refused exists={}", reason(error))),
        }
        match keyvalue::list_keys("probe/".to_string(), 16).await {
            Ok(keys) => line(&format!("kv keys={keys:?}")),
            Err(error) => line(&format!("kv refused keys={}", reason(error))),
        }
        // A key outside the granted prefix, when the test wrote a rule for one.
        match keyvalue::set("outside/key".to_string(), b"x".to_vec()).await {
            Ok(()) => line("kv outside ok"),
            Err(error) => line(&format!("kv outside refused={}", reason(error))),
        }
        match config::get_all() {
            Ok(text) => line(&format!("config all={text}")),
            Err(error) => line(&format!("config refused all={}", reason(error))),
        }
        match config::get("present") {
            Ok(Some(value)) => line(&format!("config get={value}")),
            Ok(None) => line("config get=none"),
            Err(error) => line(&format!("config refused get={}", reason(error))),
        }
        // The config the runner passes in `run(config)` too: one JSON object, same grant.
        line(&format!("config run={}", config_text.chars().take(120).collect::<String>()));
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
