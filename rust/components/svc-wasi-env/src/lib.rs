//! Fixture for the WASI grant policy (`docs/WASI-INTERFACES.md`, tier B): `wasi:cli/environment`.
//!
//! It answers two questions in the component's log, and nothing else:
//!   * `env names=[...]` - exactly which variable names the host exposed. The grant lists names, so
//!     this is the whole claim (a grant of `WA_PROBE_ALLOWED` must not expose `WA_PROBE_SECRET`).
//!   * `env <name>=<value>` for the one name it was granted, so "granted and scoped" is proven by a
//!     value and not only by a count.
//!
//! The value that must never reach the log is compared, never printed: a fixture that echoed an
//! ungranted variable would leak it into the service log, which is the failure mode the grant exists
//! to prevent.
wit_bindgen::generate!({ path: "../../../wit/kernel-v2", world: "wasi-probe-env", generate_all });

use std::time::Duration;
use wa::kernel::{lifecycle, log};
use wasi::cli::environment;
use wasi::clocks::monotonic_clock;

struct Service;

fn line(text: &str) {
    log::write(log::Level::Info, "wasi-env", text);
}

impl exports::wa::kernel::service::Guest for Service {
    async fn run(_config: String) -> Result<(), String> {
        let vars = environment::get_environment();
        let mut names: Vec<&str> = vars.iter().map(|(name, _)| name.as_str()).collect();
        names.sort_unstable();
        line(&format!("env names={names:?}"));
        for (name, value) in &vars {
            // Only the granted name's value is reported; the others are reported as "present" and
            // never quoted into the log.
            if name == "WA_PROBE_ALLOWED" {
                line(&format!("env {name}={value}"));
            }
        }
        let has_secret = vars.iter().any(|(name, _)| name == "WA_PROBE_SECRET");
        line(&format!("env secret_visible={has_secret}"));
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
