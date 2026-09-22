//! Tests for the graph. The two that matter: extraction finds the definitions we promised, and an
//! incremental reindex is actually incremental (bytes unchanged => no reparse, no churn).

use crate::extract::{extract, is_capability, simple_name};
use crate::store::Store;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn temp_dir(tag: &str) -> PathBuf {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("wa-graph-{tag}-{}-{unique}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn names_normalize_to_their_last_segment() {
    assert_eq!(simple_name("M.append_turn"), "append_turn");
    assert_eq!(simple_name("std::env::var"), "var");
    assert_eq!(simple_name("self.helper"), "helper");
    assert_eq!(simple_name("Thing::new"), "new");
}

#[test]
fn only_a_clean_host_call_is_a_capability() {
    assert!(is_capability("host.sql_exec"));
    assert!(is_capability("host.read_file"));
    // A Rust local variable named `host` is not a capability.
    assert!(!is_capability("host.db.lock().map_err"));
    assert!(!is_capability("host.getenv(name)"));
    assert!(!is_capability("host."));
    assert!(!is_capability("worker.helper"));
}

#[test]
fn rust_extraction_finds_defs_methods_and_calls() {
    let src = r#"
use std::collections::HashMap;
pub struct Thing { pub x: i32 }
impl Thing {
    pub fn new() -> Self { Thing { x: 0 } }
    fn helper(&self) -> i32 { self.x }
}
pub fn main() { let t = Thing::new(); helper_free(); }
fn helper_free() -> i32 { 1 }
"#;
    let ex = extract("src/lib.rs", "rust", src);
    let names: Vec<&str> = ex.nodes.iter().map(|n| n.name.as_str()).collect();
    assert!(names.contains(&"Thing"), "{names:?}");
    assert!(names.contains(&"new"), "{names:?}");
    assert!(names.contains(&"helper"), "{names:?}");
    assert!(names.contains(&"helper_free"), "{names:?}");
    // `new`/`helper` live in an impl, so they are methods; top-level fns are not.
    let new = ex.nodes.iter().find(|n| n.name == "new").unwrap();
    assert_eq!(new.kind, "method");
    let free = ex.nodes.iter().find(|n| n.name == "helper_free").unwrap();
    assert_eq!(free.kind, "fn");
    // The calls were recorded.
    assert!(ex
        .edges
        .iter()
        .any(|e| e.kind == "calls" && e.target == "Thing::new"));
    assert!(ex
        .edges
        .iter()
        .any(|e| e.kind == "calls" && e.target == "helper_free"));
    assert!(ex.edges.iter().any(|e| e.kind == "imports"));
}

#[test]
fn lua_extraction_finds_module_functions_requires_and_capabilities() {
    let src = r#"
local memory = require("core.memory")
local M = {}
function M.append_turn(x)
  local id = host.uuid()
  return exec(id, x)
end
local function helper() return 1 end
return M
"#;
    let ex = extract("lua/core/memory.lua", "lua", src);
    let names: Vec<&str> = ex.nodes.iter().map(|n| n.name.as_str()).collect();
    assert!(names.contains(&"M.append_turn"), "{names:?}");
    assert!(names.contains(&"helper"), "{names:?}");
    assert!(ex
        .edges
        .iter()
        .any(|e| e.kind == "imports" && e.target == "core.memory"));
    assert!(ex
        .edges
        .iter()
        .any(|e| e.kind == "capability" && e.target == "host.uuid"));
    assert!(ex
        .edges
        .iter()
        .any(|e| e.kind == "calls" && e.target == "exec"));
    // A definition must not be emitted twice (variable_declaration wraps assignment_statement).
    let dupes = ex
        .nodes
        .iter()
        .filter(|n| n.name == "M.append_turn")
        .count();
    assert_eq!(dupes, 1, "M.append_turn defined once");
}

#[test]
fn index_resolves_callers_across_files_and_capabilities() {
    let dir = temp_dir("index");
    std::fs::create_dir_all(dir.join("lua/core")).unwrap();
    std::fs::write(
        dir.join("lua/core/memory.lua"),
        "local M = {}\nfunction M.append_turn(t)\n  local id = host.uuid()\n  return t\nend\nreturn M\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("lua/core/agent.lua"),
        "local memory = require('core.memory')\nlocal function run()\n  memory.append_turn({})\nend\nreturn run\n",
    )
    .unwrap();

    let db = dir.join(".wa-graph/graph.db");
    let mut store = Store::open(&db).unwrap();
    let report = store.index(&dir, false).unwrap();
    assert_eq!(report.indexed, 2);
    assert!(
        report.resolved >= 1,
        "at least the host.uuid capability resolves"
    );

    let rows = store.explain("append_turn").unwrap();
    let def = rows
        .iter()
        .find(|(n, _, _)| n.name == "M.append_turn")
        .expect("definition found");
    let callers: Vec<&str> = def.2.iter().map(|e| e.path.as_str()).collect();
    assert!(
        callers.iter().any(|p| p.ends_with("agent.lua")),
        "caller in agent.lua: {callers:?}"
    );

    // host.uuid became a capability node, not a call to nowhere.
    let caps = store.capabilities().unwrap();
    assert!(caps
        .iter()
        .any(|(name, uses)| name == "host.uuid" && *uses >= 1));

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn reindex_is_incremental_and_drops_removed_files() {
    let dir = temp_dir("incremental");
    let file = dir.join("a.rs");
    std::fs::write(&file, "fn alpha() {}\n").unwrap();
    let db = dir.join("graph.db");

    let mut store = Store::open(&db).unwrap();
    let first = store.index(&dir, false).unwrap();
    assert_eq!(first.indexed, 1);
    assert_eq!(first.unchanged, 0);

    // Same bytes, same mtime => nothing is reparsed.
    let second = store.index(&dir, false).unwrap();
    assert_eq!(second.indexed, 0);
    assert_eq!(second.unchanged, 1);

    // A changed file is reparsed and the old definition is gone.
    std::fs::write(&file, "fn beta() {}\n").unwrap();
    let third = store.index(&dir, false).unwrap();
    assert_eq!(third.indexed, 1);
    assert!(store
        .query("beta", 10)
        .unwrap()
        .iter()
        .any(|n| n.name == "beta"));
    assert!(!store
        .query("alpha", 10)
        .unwrap()
        .iter()
        .any(|n| n.name == "alpha"));

    // A removed file is dropped from the graph.
    std::fs::remove_file(&file).unwrap();
    let fourth = store.index(&dir, false).unwrap();
    assert_eq!(fourth.removed, 1);
    assert!(!store
        .query("beta", 10)
        .unwrap()
        .iter()
        .any(|n| n.name == "beta"));

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn path_walks_resolved_edges_and_ignores_doc_mentions() {
    let dir = temp_dir("path");
    std::fs::write(
        dir.join("x.rs"),
        "fn a() { b(); }\nfn b() { c(); }\nfn c() {}\n",
    )
    .unwrap();
    // A doc that mentions a and c must not create a shortcut a -> c.
    std::fs::write(
        dir.join("notes.md"),
        "calling `c` from `a` should not be a graph hop\n",
    )
    .unwrap();
    let db = dir.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    store.index(&dir, false).unwrap();

    let chain = store.path("a", "c").unwrap().expect("a route exists");
    let names: Vec<&str> = chain.iter().map(|(n, _)| n.name.as_str()).collect();
    assert_eq!(
        names,
        vec!["a", "b", "c"],
        "the route goes through b, not a doc mention"
    );

    std::fs::remove_dir_all(&dir).ok();
}
