//! One wait for every component host (ARCHITECTURE.md law 17, `change/component-hosts-share-the-wait`).
//!
//! Measured 27/11: five hosts answered "how long may this call wait" with their own `DEFAULT_TIMEOUT_MS = 2_000` and
//! their own `WA_*_COMPONENT_TIMEOUT_MS` knob - two seconds, sixty times below the codemode seam's 120 000 for the
//! same question. The law's row (`scripts/test-one-question-one-owner.mjs`) derives the names from the tree; this test
//! proves the VALUES come from the one owner.

use wa_component_wait::{DEFAULT_WAIT_MS, MAX_WAIT_MS};

#[test]
fn every_host_takes_the_one_component_wait() {
    // No environment override in this test's own process: the default is the shared budget's 60 s, not 2 s.
    std::env::remove_var(wa_component_wait::ENV);
    assert_eq!(wa_component_wait::wait_ms(), DEFAULT_WAIT_MS);
    assert_eq!(DEFAULT_WAIT_MS, 60_000, "the window is the node's shared wait budget, not a private 2 s");

    let hooks = wa_kernel_runtime::hooks_host::Config::from_env();
    assert_eq!(hooks.timeout_ms, DEFAULT_WAIT_MS);
    let mesh = wa_kernel_runtime::mesh_host::Config::from_env();
    assert_eq!(mesh.timeout_ms, DEFAULT_WAIT_MS);
    let selfloop = wa_kernel_runtime::selfloop_host::Config::from_env();
    assert_eq!(selfloop.timeout_ms, DEFAULT_WAIT_MS);
    let stt = wa_kernel_runtime::stt_host::Config::installed();
    assert_eq!(stt.timeout_ms, DEFAULT_WAIT_MS);
    // memory keeps a MEASURED per-operation table (its own reason, in its own comment); what it may no longer do is
    // invent a number for an operation it has never measured.
    let memory = wa_kernel_runtime::memory_host::Config::from_env();
    assert!(memory.timeout_ms.is_none(), "no override is set, so the measured table decides");
}

#[test]
fn one_knob_and_it_is_clamped_by_the_owner() {
    std::env::set_var(wa_component_wait::ENV, "1500");
    assert_eq!(wa_kernel_runtime::hooks_host::Config::from_env().timeout_ms, 1_500);
    std::env::set_var(wa_component_wait::ENV, "9999999");
    assert_eq!(wa_component_wait::wait_ms(), MAX_WAIT_MS, "an operator cannot ask for an unbounded window");
    std::env::remove_var(wa_component_wait::ENV);
}
