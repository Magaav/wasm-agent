//! Processes, operations and automation: exec, the supervised operation record, local jobs, the
//! completion enqueue, owned subagents, resources, and the node's one root and disk cap
//! (docs/ONEROOT.md). The handlers are in crate::host and crate::disk.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    plain!("exec", RunsProcess, crate::host::exec, "Run one foreground command as a supervised operation and return a bounded view of its output"),
    plain!("exec_timeout", ReadOnly, crate::host::exec_timeout, "The effective foreground deadline an exec would be given"),
    plain!("operation", RunsProcess, crate::host::operation, "Launch, observe, read, wait for or cancel a supervised external operation"),
    plain!("jobs", WritesFiles, crate::host::jobs, "Manage local automation definitions and their enabled state; jobs never execute here"),
    plain!("enqueue_completion", WritesFiles, crate::host::enqueue_completion, "Internal scheduler enqueue for a finished background completion"),
    plain!("subagent", RunsProcess, crate::host::subagent, "Start, inspect, wait for, message or cancel an owned child agent on its own thread"),
    plain!("resource", WritesFiles, crate::host::resource, "Supervised host resources: leases, receipts and their settlement"),
    // One root and one clean (`docs/ONEROOT.md`): what the node's state root holds, what `wa clean`
    // may reclaim and why it keeps the rest, the pins, and the disk cap that refuses new heavy work.
    plain!("disk", WritesFiles, crate::disk::capability, "The node's one root: its size and disk usage, `wa clean` with pins and retention, and the disk cap before new work"),
];
