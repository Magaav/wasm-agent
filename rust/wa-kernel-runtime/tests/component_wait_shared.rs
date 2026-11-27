//! One wait for every component host (ARCHITECTURE.md law 17, `change/component-hosts-share-the-wait`).
//!
//! Measured 27/11: five hosts answered "how long may this call wait" with their own `DEFAULT_TIMEOUT_MS = 2_000` and
//! their own `WA_*_COMPONENT_TIMEOUT_MS` knob - two seconds, sixty times below the codemode seam's 120 000 for the
//! same question. The law's row (`scripts/test-one-question-one-owner.mjs`) derives the names from the tree; this test
//! proves the VALUES come from the one owner, and that they cannot come from the environment.

use wa_component_wait::{DEFAULT_WAIT_MS, MAX_WAIT_MS};

#[test]
fn every_host_takes_the_one_component_wait() {
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
    // memory keeps a MEASURED per-operation table (its own reason, in its own comment); its `from_env` injects no
    // window at all, so the table decides - and an operation it has never measured takes the owner's wait.
    let memory = wa_kernel_runtime::memory_host::Config::from_env();
    assert!(memory.timeout_ms.is_none(), "no window comes from the environment");
}

#[test]
fn no_environment_variable_can_move_a_component_window() {
    // The reviewer's rule (27/11): a new env override in product code is a second answer again. Set every name this
    // tree has ever used for one and prove the value does not move.
    for name in [
        "WA_COMPONENT_WAIT_MS",
        "WA_HOOKS_COMPONENT_TIMEOUT_MS",
        "WA_MESH_COMPONENT_TIMEOUT_MS",
        "WA_SELFLOOP_COMPONENT_TIMEOUT_MS",
        "WA_MEMORY_COMPONENT_TIMEOUT_MS",
        "WA_CODEMODE_COMPONENT_TIMEOUT_MS",
    ] {
        std::env::set_var(name, "1");
    }
    assert_eq!(wa_kernel_runtime::hooks_host::Config::from_env().timeout_ms, DEFAULT_WAIT_MS);
    assert_eq!(wa_kernel_runtime::mesh_host::Config::from_env().timeout_ms, DEFAULT_WAIT_MS);
    assert_eq!(wa_kernel_runtime::stt_host::Config::installed().timeout_ms, DEFAULT_WAIT_MS);
    assert!(wa_kernel_runtime::memory_host::Config::from_env().timeout_ms.is_none());
    for name in [
        "WA_COMPONENT_WAIT_MS",
        "WA_HOOKS_COMPONENT_TIMEOUT_MS",
        "WA_MESH_COMPONENT_TIMEOUT_MS",
        "WA_SELFLOOP_COMPONENT_TIMEOUT_MS",
        "WA_MEMORY_COMPONENT_TIMEOUT_MS",
        "WA_CODEMODE_COMPONENT_TIMEOUT_MS",
    ] {
        std::env::remove_var(name);
    }
    assert_eq!(MAX_WAIT_MS, 300_000);
}
