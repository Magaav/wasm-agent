//! The code-mode sandbox (docs/CORE-SPLIT.md, code mode): the checksum-pinned QuickJS VM and the
//! wa:codemode seam over it. The handlers are in crate::quickjs and crate::codemode_seam.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    plain!("quickjs", RunsProcess, crate::quickjs::capability, "The checksum-pinned QuickJS sandbox in wasmtime: fuel-metered, deadline-bounded, owner-checked, 4 sessions; effects only through nested tool calls"),
    // The code-mode seam (docs/CORE-SPLIT.md, "code mode"): the `codemode` component owns the guest's
    // protocol — the fence, its tool table, searchTools/describeTool, the admit/deliver order and the
    // script's report — and imports `wa:kernel/quickjs` for the sandbox it is not allowed to contain.
    // `WA_CODEMODE_COMPONENT=1` is what routes `lua/core/codemode.lua` here; without it the native path
    // runs, so this capability is inert on a node that never opts in.
    plain!("codemode", RunsProcess, crate::codemode_seam::capability, "One wa:codemode step against the installed codemode component: open a script, advance it past one tool call, or finish it and read what it did"),
];
