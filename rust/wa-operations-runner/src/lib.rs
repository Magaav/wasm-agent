//! The operations runner as its own crate (`ready-operations-slice-2.md`).
//!
//! `operations` is the runner itself - moved here from `wa-capabilities` without rewriting its logic, so the
//! host stops carrying it and a landing in this area stops shipping the node binary. What it cannot own (the
//! node's run/cancel state, its tool-progress rows, its subagent context, its disk cap) is asked of the
//! process that embeds it through `node::NodeFacts`.

/// The pure file questions live in `wa-files` (a leaf both this runner and the node link).
pub use wa_files as files;
pub mod node;
/// The live facts behind a long tool call's row (docs/TOOL-PROGRESS.md): written here, beside the wait
/// loops that produce them, and read by every surface through `wa_tool_progress`.
pub mod tool_progress;
pub mod operations;

/// The library the runner itself is built on. Re-exported so the embedding process has ONE edge to
/// this area (wa-capabilities uses quarantine for claims and scrub_git_env for child builds); stage B
/// cuts that edge by giving those two callers their own home.
pub use wa_operation;

#[cfg(test)]
mod test_facts;
#[cfg(test)]
mod host_tests;
