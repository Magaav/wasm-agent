//! Paths, the environment and the process: the resolved home/config/data/temp directories, the
//! PATH a spawned child inherits, the clock and the ids, and the identity build_identity reports.
//! The handlers are in crate::host.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    plain!("getenv", ReadOnly, crate::host::getenv, "Read one environment value as the host resolved it (config file first, then the process)"),
    // The PATH a spawned child gets is the process's, not the config's: the approval has to name the
    // interpreter the kernel actually starts (docs/VAULT.md, round 7).
    plain!("executable_on_path", ReadOnly, crate::host::executable_on_path, "The file a bare program name resolves to on the PATH a spawned child inherits"),
    plain!("paths", ReadOnly, crate::host::paths, "The resolved home/config/data/cache/temp directories; never build a path by hand"),
    plain!("canonical_path", ReadOnly, crate::host::canonical_path, "Canonicalise a path without requiring it to exist"),
    plain!("platform", ReadOnly, crate::host::platform, "This node's platform, architecture and executable family"),
    plain!("now", ReadOnly, crate::host::now, "Wall-clock time"),
    plain!("monotonic_ms", ReadOnly, crate::host::monotonic_ms, "A monotonic millisecond counter for measuring elapsed time"),
    plain!("sleep", ReadOnly, crate::host::sleep, "Block this interpreter for a bounded number of milliseconds"),
    plain!("uuid", ReadOnly, crate::host::uuid, "A fresh random UUID"),
    plain!("sha256", ReadOnly, crate::host::sha256, "SHA-256 of a string, as hex"),
    plain!("runtime_info", ReadOnly, crate::host::runtime_info, "Build and runtime identity of this binary"),
    plain!("process_identity", ReadOnly, crate::host::process_identity, "This process id and the boot tag it was given, without reading the binary to hash it"),
    plain!("build_identity", ReadOnly, crate::host::build_identity, "The one name for this build: its commit (short), whether the tree was dirty, and the full id"),
    plain!("system_resources", ReadOnly, crate::host::system_resources, "CPU, memory and disk facts for this machine; passed {quick:true} it skips the 120 ms CPU delta and says the figure was not measured"),
    plain!("node_identity", ReadOnly, crate::host::node_identity, "This node's identity and network role"),
    plain!("run_state", ReadOnly, crate::host::run_state, "The state of a run this node admitted: queued, running or unknown, so a wake can tell a queued resume from a lost one"),
    plain!("run_cancelled", ReadOnly, crate::host::run_cancelled, "Whether the current run has been cancelled, for cooperative loops"),
    plain!("log", Device, crate::host::log, "Print one redacted line to this process's standard error"),
];
