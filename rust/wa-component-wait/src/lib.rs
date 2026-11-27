//! The ONE answer to "how long may a component call wait" (ARCHITECTURE.md law 17: one question, one
//! owner).
//!
//! Measured 27/11: five hosts in `wa-kernel-runtime` (hooks, mesh, selfloop, memory, stt) each carried
//! `DEFAULT_TIMEOUT_MS = 2_000` and its own `WA_*_COMPONENT_TIMEOUT_MS` knob, `wa-capabilities`' codemode seam
//! carried a sixth default at 120 000, and the hooks COMPONENT clamped its caller at `MAX_TIMEOUT_MS = 60_000`. Six
//! answers to one question, two orders of magnitude apart, and none of them the number the rest of the node uses for a
//! wait (`lua/core/codemode_pending.lua`: `M.DEFAULT_WAIT_S = 60`, `M.MAX_WAIT_S = 300`, then a pending handle).
//!
//! There is NO environment override here, and none of the five knobs survives: a window an environment variable can
//! move at run time is a second answer again, and the one owner is a constant a caller passes in. A host that needs a
//! different window has to say so in code, where a reader can find it.

use std::sync::atomic::{AtomicU64, Ordering};

/// The window a component call is given: the same 60 s the node's shared wait budget names.
pub const DEFAULT_WAIT_MS: u64 = 60_000;

/// The most any component call may be given: the shared budget's own maximum (300 s). Nothing reads it from the
/// environment; it is the ceiling a caller is clamped by.
pub const MAX_WAIT_MS: u64 = 300_000;

static EXPIRIES: AtomicU64 = AtomicU64::new(0);

/// The window for one component call.
pub const fn wait_ms() -> u64 {
    DEFAULT_WAIT_MS
}

/// A deadline expired. Called from the place that saw it (a frozen guest is stopped by its epoch, and wasmtime says
/// so), so `expiries()` counts facts instead of guesses: "how often does the window expire" is a number.
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
    fn the_window_is_the_shared_budget_and_its_maximum_is_its_maximum() {
        assert_eq!(DEFAULT_WAIT_MS, 60_000);
        assert_eq!(MAX_WAIT_MS, 300_000);
        assert_eq!(wait_ms(), DEFAULT_WAIT_MS);
    }

    #[test]
    fn there_is_no_environment_knob() {
        // The one thing this crate must NOT grow back: a run-time override. If a name were read here, an operator's
        // shell could make two nodes answer one question differently.
        for name in ["WA_COMPONENT_WAIT_MS", "WA_HOOKS_COMPONENT_TIMEOUT_MS", "WA_MESH_COMPONENT_TIMEOUT_MS"] {
            std::env::set_var(name, "1");
        }
        assert_eq!(wait_ms(), DEFAULT_WAIT_MS);
        for name in ["WA_COMPONENT_WAIT_MS", "WA_HOOKS_COMPONENT_TIMEOUT_MS", "WA_MESH_COMPONENT_TIMEOUT_MS"] {
            std::env::remove_var(name);
        }
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
