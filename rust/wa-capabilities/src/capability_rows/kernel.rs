//! The kernel's seams onto the installed components (docs/CORE-SPLIT.md): components, features,
//! services, one MCP call, state, memory, selfloop and hooks. The handlers are in
//! wa_kernel_runtime and wa-features, the latter reached through crate::features.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    plain!("components", ReadOnly, wa_kernel_runtime::components::components, "List installed WASI components: pin state and declared capabilities"),
    // The feature resolver (docs/FEATURES.md): one answer per feature - installed (with its verified
    // sha), enabled, source (env|policy|default), the active path (component|native) and the reason -
    // read live from `policy.json`, so a switch takes effect without a restart. `wa features` and
    // `services {"action":"features"}` print the same document.
    plain!("features", ReadOnly, crate::features::capability, "The node's feature switches: per feature, installed sha, enabled, source (env/policy/default), active path (component/native) and why, resolved live from policy.json by one resolver"),
    plain!("service", RunsProcess, wa_kernel_runtime::services::service, "Supervise long-lived WASI service components (docs/SERVICE-COMPONENTS.md): start, stop, status, logs, the transactional upgrade, the effective configuration profile and the start-by-imports reconcile"),
    plain!("component_mcp", RunsProcess, wa_kernel_runtime::components::component_mcp, "One MCP request (probe or call) against a pinned WASI component, with exactly the granted env/file/network capabilities"),
    plain!("state", WritesFiles, wa_kernel_runtime::state_host::capability, "Component state: status, dry run, export, import and verify of a component's versioned kv namespace, its migration journal and its snapshots"),
    // The memory seam (docs/MEMORY.md, docs/KERNEL.md "Memory as a component"): the `memory` component
    // answers recall/remember/forget/list/search_messages/sessions over a scoped `wa:kernel/sql`
    // grant. `WA_MEMORY_COMPONENT=1` is what routes `lua/core/memory.lua` here; without it the native
    // path is used, so this capability is inert on a node that never opts in.
    plain!("memory", WritesFiles, wa_kernel_runtime::memory_host::capability, "One wa:memory call against the installed memory component: remember, recall, forget, list, search_messages, sessions or the retention decision, over a scoped wa:kernel/sql grant"),
    // The self-loop seam (docs/CORE-SPLIT.md, docs/KERNEL.md "The self-loop as a component"): the
    // `selfloop` component answers the wake/notes/probe state machine over its own scoped
    // `wa:kernel/sql` grant. `WA_SELFLOOP_COMPONENT=1` is what routes `lua/core/selfloop.lua` here;
    // without it the native path runs, so this capability is inert on a node that never opts in.
    plain!("selfloop", WritesFiles, wa_kernel_runtime::selfloop_host::capability, "One wa:selfloop call against the installed selfloop component: the wake/notes/probe state machine (schedule, list, cancel, summary, notes, publish, plan, claim, settle, finish, turn) over a scoped wa:kernel/sql grant"),
    // The hooks/mods seam (docs/CORE-SPLIT.md, docs/HOOK-EVENTS.md): the `hooks` component answers
    // "what is configured for this event", "which entries run, in which order", "what does this answer
    // mean" and "what does the footer say". `WA_HOOKS_COMPONENT=1` is what routes
    // `lua/core/hooks.lua` here; without it the native engine runs, so this capability is inert on a
    // node that never opts in. The component holds no capability: the node reads the config files and
    // runs the hooks, and this call never runs a process.
    plain!("hooks", ReadOnly, wa_kernel_runtime::hooks_host::capability, "One wa:hooks call against the installed hooks component: the catalogue, the merged config view, the entries an event runs in order, one hook's answer interpreted into the decision, or the footer segment"),
];
