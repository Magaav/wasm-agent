//! The code graph (docs/GRAPH.md): the index, one query, and the exact source reads. The handlers
//! are in crate::graph.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    plain!("graph_index", WritesFiles, crate::graph::graph_index, "Build or refresh the content-hashed code graph, reparsing only changed files"),
    plain!("graph_query", ReadOnly, crate::graph::graph_query, "Run one structured query against the code graph"),
    plain!("graph_search", ReadOnly, crate::graph::graph_search, "Find symbols by concept or identifier in the code graph"),
    plain!("graph_source", ReadOnly, crate::graph::graph_source, "Exact source of one graph symbol, with continuation"),
    plain!("graph_sources", ReadOnly, crate::graph::graph_sources, "Exact source of several graph symbols in one call"),
    plain!("graph_notify", ReadOnly, crate::graph::graph_notify, "Report an explicit indexing failure so later queries refuse instead of returning stale results"),
    plain!("graph_explain", ReadOnly, crate::graph::graph_explain, "Explain what the graph knows about one symbol"),
    plain!("graph_path", ReadOnly, crate::graph::graph_path, "Shortest path between two graph symbols"),
    plain!("graph_caps", ReadOnly, crate::graph::graph_caps, "Which code calls which capability"),
    plain!("graph_stats", ReadOnly, crate::graph::graph_stats, "Index size and freshness counters"),
    plain!("graph_overview", ReadOnly, crate::graph::graph_overview, "A bounded structural overview of the indexed tree"),
    plain!("graph_impact", ReadOnly, crate::graph::graph_impact, "Resolved callers/dependencies of a symbol at a given depth"),
    plain!("graph_status", ReadOnly, crate::graph::graph_status, "Whether the graph index is present, current and complete"),
    plain!("graph_snapshot", WritesFiles, crate::graph::graph_snapshot, "One consistent copy of a graph store, taken under the store's own lock so the component cannot be writing it"),
    plain!("graph_patch_audit", ReadOnly, crate::graph::graph_patch_audit, "Which symbols a changeset reaches, from the patch itself"),
];
