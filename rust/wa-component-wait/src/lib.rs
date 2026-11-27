//! The ONE answer to "how long may a component call wait" (ARCHITECTURE.md law 17: one question, one
//! owner).
//!
//! Measured 27/11: five hosts in `wa-kernel-runtime` (hooks, mesh, selfloop, memory, stt) each carried
//! `DEFAULT_TIMEOUT_MS = 2_000` and its own `WA_*_COMPONENT_TIMEOUT_MS` knob, `wa-capabilities`' codemode seam
//! carried a fourth default at 120 000, `graph.rs` its own parse knob, and the hooks COMPONENT clamped its caller at
//! `MAX_TIMEOUT_MS = 60_000`. Six answers to one question, two orders of magnitude apart, and none of them the number
//! the rest of the node uses for a wait (`lua/core/codemode_pending.lua`: `M.DEFAULT_WAIT_S = 60`, `M.MAX_WAIT_S = 300`,
//! then a pending handle).
//!
//! So: one default, one maximum, one knob, and a counter, here. A host asks [`wait_ms`] (or, when it has a measured
//! default of its own, [`override_ms`]) and nothing else decides.

use std::sync::atomic::{AtomicU64, Ordering};

/// The default window a component call is given: the same 60 s the node's shared wait budget names.
pub const DEFAULT_WAIT_MS: u64 = 60_000;

/// The most any component call may be given: the shared budget's own maximum (300 s).
pub const MAX_WAIT_MS: u64 = 300_000;

/// The ONE operator knob. It replaces five per-host ones, and it is parsed here, not by a caller.
pub const ENV: &str = "WA_COMPONENT_WAIT_MS";

static EXPIRIES: AtomicU64 = AtomicU64::new(0);

/// Rewritten by history: the counter exists so the question "how often does the window expire?" has a number rather
/// than an opinion. Nothing is expired silently: a caller that turns a deadline into an error calls [`note_expiry`].
fn parse(value: Option<String>) -> Option<u64> {
    value
        .and_then(|text| text.trim().parse::<u64>().ok())
        .filter(|ms| *ms > 0)
        .map(|ms| ms.min(MAX_WAIT_MS))
}

/// The operator's override, already clamped, or `None`. A caller whose default is measured per operation
/// (`memory_host`) takes this so its own table survives while the five knobs become one.
pub fn override_ms() -> Option<u64> {
    parse(std::env::var(ENV).ok())
}

/// The window for one component call.
pub fn wait_ms() -> u64 {
    override_ms().unwrap_or(DEFAULT_WAIT_MS)
}

/// A deadline expired. Called from the place that saw it (a frozen guest is stopped by its epoch, and wasmtime says
/// so), so `expiries()` counts facts instead of guesses.
pub fn note_expiry() {
    EXPIRIES.fetch_add(1, Ordering::Relaxed);
}

/// How many component calls have expired since this process started.
pub fn expiries() -> u64 {
    EXPIRIES.load(Ordering::Relaxed)
}

/// Does this error text mean the guest was stopped by its deadline? wasmtime reports an epoch trap as `interrupt`, and
/// it is the only place a host learns the window expired.
pub fn is_expiry(error: &str) -> bool {
    error.contains("interrupt") || error.contains("epoch")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_default_is_the_shared_budget_and_the_maximum_is_its_maximum() {
        assert_eq!(DEFAULT_WAIT_MS, 60_000);
        assert_eq!(MAX_WAIT_MS, 300_000);
    }

    #[test]
    fn an_override_is_clamped_to_the_shared_maximum() {
        std::env::set_var(ENV, "999999");
        assert_eq!(wait_ms(), MAX_WAIT_MS);
        std::env::set_var(ENV, "0");
        assert_eq!(wait_ms(), DEFAULT_WAIT_MS, "zero is not a window");
        std::env::remove_var(ENV);
        assert_eq!(wait_ms(), DEFAULT_WAIT_MS);
    }

    #[test]
    fn an_expiry_is_a_fact_once_it_is_counted() {
        let before = expiries();
        note_expiry();
        assert_eq!(expiries(), before + 1);
        assert!(is_expiry("component call: wasm trap: interrupt"));
        assert!(!is_expiry("component_unavailable: no manifest"));
    }
}
