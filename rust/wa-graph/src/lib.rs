//! wa-graph — a wasm-agent-native code graph.
//!
//! Index a repository with tree-sitter (Rust, Lua, Markdown) into SQLite, then answer
//! `explain` / `path` / `query` without a grep-and-read round trip. The intended integration is a
//! `host.graph_*` capability so a Lua run can query its own code; this crate is the spike that
//! proves the value before that wiring.

pub mod extract;
pub mod store;

#[cfg(test)]
mod tests;

pub use store::{IndexReport, NodeRow, Stats, Store};
