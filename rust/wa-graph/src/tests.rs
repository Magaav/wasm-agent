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
fn bash_extraction_finds_functions_sources_and_calls() {
    let src = "source ./lib.sh\ngreet() { echo hi; }\nfunction helper { echo x; }\ngreet world\n";
    let ex = extract("scripts/run.sh", "bash", src);
    let names: Vec<&str> = ex.nodes.iter().map(|n| n.name.as_str()).collect();
    assert!(names.contains(&"greet"), "{names:?}");
    assert!(names.contains(&"helper"), "{names:?}");
    assert!(ex
        .edges
        .iter()
        .any(|e| e.kind == "imports" && e.target == "./lib.sh"));
    assert!(ex
        .edges
        .iter()
        .any(|e| e.kind == "calls" && e.target == "greet"));
}

#[test]
fn powershell_extraction_finds_functions_and_imports() {
    let src = ". ./lib.ps1\nImport-Module Foo\nfunction Get-Thing { 1 }\nfunction helper { 2 }\nGet-Thing\n";
    let ex = extract("scripts/run.ps1", "powershell", src);
    let names: Vec<&str> = ex.nodes.iter().map(|n| n.name.as_str()).collect();
    assert!(names.contains(&"Get-Thing"), "{names:?}");
    assert!(names.contains(&"helper"), "{names:?}");
    assert!(
        ex.edges
            .iter()
            .any(|e| e.kind == "imports" && e.target == "./lib.ps1"),
        "{:?}",
        ex.edges
    );
    assert!(ex
        .edges
        .iter()
        .any(|e| e.kind == "calls" && e.target == "Get-Thing"));
}

#[test]
fn a_reader_never_sees_an_uncommitted_index_write() {
    // The whole index run is one BEGIN IMMEDIATE transaction, so a reader sees the previous
    // committed graph until it commits - never a half-indexed file.
    let dir = temp_dir("atomic");
    std::fs::write(dir.join("a.rs"), "fn alpha() {}\n").unwrap();
    let db = dir.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    store.index(&dir, false).unwrap();

    // Simulate the middle of a reindex: an open write transaction has replaced a file's nodes.
    let writer = rusqlite::Connection::open(&db).unwrap();
    writer.execute_batch("BEGIN IMMEDIATE").unwrap();
    writer
        .execute("DELETE FROM nodes WHERE path='a.rs'", [])
        .unwrap();
    writer
        .execute(
            "INSERT INTO nodes(kind,name,path,line,col,lang,detail) VALUES('fn','beta','a.rs',1,0,'rust',NULL)",
            [],
        )
        .unwrap();

    let reader = Store::open_readonly(&db).unwrap();
    assert!(reader
        .query("alpha", 5)
        .unwrap()
        .iter()
        .any(|n| n.name == "alpha"));
    assert!(!reader
        .query("beta", 5)
        .unwrap()
        .iter()
        .any(|n| n.name == "beta"));

    writer.execute_batch("ROLLBACK").unwrap();
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn snapshot_verification_catches_changes_even_without_a_watcher_event() {
    let dir = temp_dir("freshness");
    let source = dir.join("a.rs");
    std::fs::write(&source, "fn alpha() {}\n").unwrap();
    let db = dir.join("graph.db");
    let mut writer = Store::open(&db).unwrap();
    writer.index(&dir, false).unwrap();
    let reader = Store::open_readonly(&db).unwrap();
    assert!(reader.verify_snapshot(&dir).unwrap());

    // Same length, no event required: the exact bytes, not metadata, are compared.
    std::fs::write(&source, "fn bravo() {}\n").unwrap();
    assert!(!reader.verify_snapshot(&dir).unwrap());
    writer.index(&dir, false).unwrap();
    assert!(reader.verify_snapshot(&dir).unwrap());

    let added = dir.join("new.lua");
    std::fs::write(&added, "return 1\n").unwrap();
    assert!(!reader.verify_snapshot(&dir).unwrap());
    writer.index(&dir, false).unwrap();
    assert!(reader.verify_snapshot(&dir).unwrap());

    std::fs::remove_file(&added).unwrap();
    assert!(!reader.verify_snapshot(&dir).unwrap());
    writer.index(&dir, false).unwrap();
    assert!(reader.verify_snapshot(&dir).unwrap());
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn snapshot_verification_rejects_a_different_root() {
    let first = temp_dir("root-first");
    let second = temp_dir("root-second");
    std::fs::write(first.join("a.rs"), "fn alpha() {}\n").unwrap();
    std::fs::write(second.join("a.rs"), "fn alpha() {}\n").unwrap();
    let db = first.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    store.index(&first, false).unwrap();
    assert!(!store.verify_snapshot(&second).unwrap());
    std::fs::remove_dir_all(&first).ok();
    std::fs::remove_dir_all(&second).ok();
}

#[test]
fn watch_indexes_initially_and_stops() {
    let dir = temp_dir("watch");
    std::fs::write(dir.join("a.rs"), "fn watched() {}\n").unwrap();
    let db = dir.join("graph.db");
    let handle = crate::watch::spawn(dir.clone(), db.clone()).unwrap();
    let mut found = false;
    for _ in 0..50 {
        if let Ok(store) = Store::open_readonly(&db) {
            if store
                .query("watched", 5)
                .map(|rows| !rows.is_empty())
                .unwrap_or(false)
            {
                found = true;
                break;
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    drop(handle);
    assert!(found, "the watcher indexed the root");
    std::fs::remove_dir_all(&dir).ok();
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
    assert!(
        def.2
            .iter()
            .any(|e| e.path == "lua/core/agent.lua" && e.line == 3),
        "incoming edges must retain the call site, not only the enclosing function"
    );

    // host.uuid became a capability node, not a call to nowhere.
    let caps = store.capabilities().unwrap();
    assert!(caps
        .iter()
        .any(|(name, uses)| name == "host.uuid" && *uses >= 1));

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn host_capability_never_resolves_to_an_unrelated_function() {
    let dir = temp_dir("capability-name-collision");
    std::fs::write(
        dir.join("run.lua"),
        "function run() host.subagent('start', '{}') end\nfunction subagent() end\n",
    )
    .unwrap();
    let db = dir.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    store.index(&dir, false).unwrap();

    let path = store
        .path("run", "host.subagent")
        .unwrap()
        .expect("host call reaches capability");
    assert_eq!(path.last().unwrap().0.kind, "capability");
    assert_eq!(path.last().unwrap().0.path, "<capability>");
    assert!(store.path("run", "subagent").unwrap().is_none());
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn query_ranks_named_functions_before_path_matches() {
    let dir = temp_dir("query-rank");
    std::fs::create_dir_all(dir.join("lua/core")).unwrap();
    std::fs::create_dir_all(dir.join("docs")).unwrap();
    std::fs::write(
        dir.join("lua/core/subagents.lua"),
        "local x = 1\nfunction wa_subagents() return x end\n",
    )
    .unwrap();
    std::fs::write(dir.join("docs/SUBAGENTS.md"), "# Subagents\n").unwrap();
    let db = dir.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    store.index(&dir, false).unwrap();

    let top = store.query("subagents", 1).unwrap();
    assert_eq!(top.len(), 1);
    assert_eq!(top[0].name, "wa_subagents");
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn lua_pcall_of_named_function_is_a_path_edge() {
    let dir = temp_dir("lua-pcall");
    std::fs::write(
        dir.join("run.lua"),
        "local M = {}\nfunction M.start() end\nfunction M.control() return M.start() end\nfunction wa_subagents() return pcall(M.control, {}) end\n",
    ).unwrap();
    let db = dir.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    store.index(&dir, false).unwrap();

    let path = store
        .path("wa_subagents", "M.start")
        .unwrap()
        .expect("pcall invokes M.control");
    let names: Vec<&str> = path.iter().map(|(node, _)| node.name.as_str()).collect();
    assert_eq!(names, vec!["wa_subagents", "M.control", "M.start"]);
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn rust_route_reaches_string_named_lua_entrypoint() {
    let dir = temp_dir("rust-lua-route");
    std::fs::create_dir_all(dir.join("tests")).unwrap();
    std::fs::write(
        dir.join("serve.rs"),
        "fn dispatch(lua: &Lua, route: &str) { match route { \"/subagents\" => subagent_reply(lua), _ => () } }\nfn subagent_reply(lua: &Lua) { lua.call_string(\"wa_subagents\", &[]); }\nfn dynamic(lua: &Lua, name: &str) { lua.call_string(name, &[]); }\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("subagents.lua"),
        "function wa_subagents() return pcall(M.control, {}) end\nfunction M.control() return M.start() end\nfunction M.start() end\nfunction M.start_session() end\nfunction start() end\n",
    )
    .unwrap();
    std::fs::write(dir.join("tests/route.rs"), "fn sample() { let p = \"/subagents\"; }\n").unwrap();
    let db = dir.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    store.index(&dir, false).unwrap();

    let routes = store.query("/subagents", 10).unwrap();
    assert_eq!(routes[0].path, "serve.rs", "runtime route before test literals");
    assert!(routes.iter().any(|node| node.path == "tests/route.rs"));
    assert!(store
        .explain("M.start")
        .unwrap()
        .iter()
        .all(|(node, _, _)| node.name == "M.start"));
    let bare = store.explain("start").unwrap();
    assert!(bare.iter().any(|(node, _, _)| node.name == "M.start"));
    assert!(bare.iter().any(|(node, _, _)| node.name == "start"));
    assert!(!bare.iter().any(|(node, _, _)| node.name == "M.start_session"));
    let path = store
        .path("dispatch", "M.start")
        .unwrap()
        .expect("cross-language path");
    let names: Vec<&str> = path.iter().map(|(node, _)| node.name.as_str()).collect();
    assert_eq!(
        names,
        vec![
            "dispatch",
            "subagent_reply",
            "wa_subagents",
            "M.control",
            "M.start"
        ]
    );
    assert!(path[1].1.contains("serve.rs:1"), "call-site in each path hop");
    assert!(path[2].1.contains("serve.rs:2"));
    assert!(path[3].1.contains("subagents.lua:1"));
    assert!(path[4].1.contains("subagents.lua:2"));
    assert!(store.path("dynamic", "M.start").unwrap().is_none());
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn old_content_only_stamps_are_reindexed_after_extractor_upgrade() {
    let dir = temp_dir("extract-version");
    std::fs::write(dir.join("run.lua"), "function run() end\n").unwrap();
    let db = dir.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    assert_eq!(store.index(&dir, false).unwrap().indexed, 1);
    let conn = rusqlite::Connection::open(&db).unwrap();
    conn.execute("UPDATE files SET hash=substr(hash,3)", [])
        .unwrap();
    assert_eq!(store.index(&dir, false).unwrap().indexed, 1);
    assert_eq!(store.index(&dir, false).unwrap().unchanged, 1);
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

#[test]
fn path_does_not_bridge_through_a_shared_callee() {
    // Two functions that both call `shared` are not connected by it: a route through a caller, or
    // through a shared leaf, is not a route. Before the fix `path a b` followed the incoming edge
    // at `shared` and answered `a -> shared -> b` - a plausible wrong answer.
    let dir = temp_dir("path-direction");
    std::fs::write(
        dir.join("x.rs"),
        "fn shared() {}\nfn a() { shared(); }\nfn b() { shared(); }\n",
    )
    .unwrap();
    let db = dir.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    store.index(&dir, false).unwrap();

    assert!(
        store.path("a", "shared").unwrap().is_some(),
        "a reaches the function it calls"
    );
    assert!(
        store.path("a", "b").unwrap().is_none(),
        "a must not reach b through a shared callee"
    );
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn a_dofile_alias_resolves_a_dotted_call() {
    // `local provider = dofile('lua/core/provider.lua')` then `provider.budget()` must resolve to
    // `M.budget` in that file. Only `require` aliases were recorded, and the path was built for a
    // dotted module, so dofile calls stayed unresolved whenever the member name was ambiguous.
    let dir = temp_dir("dofile-alias");
    std::fs::create_dir_all(dir.join("lua/core")).unwrap();
    std::fs::write(
        dir.join("lua/core/provider.lua"),
        "local M = {}\nfunction M.budget()\n  local budget = 9\n  return budget\nend\nreturn M\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("lua/core/agent.lua"),
        "local provider = dofile('lua/core/provider.lua')\nlocal budget = 9\nlocal function run()\n  return provider.budget()\nend\nreturn run\n",
    )
    .unwrap();
    let db = dir.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    store.index(&dir, false).unwrap();

    let rows = store.explain("M.budget").unwrap();
    let def = rows
        .iter()
        .find(|(n, _, _)| n.name == "M.budget")
        .expect("M.budget is defined");
    let callers: Vec<&str> = def.2.iter().map(|e| e.path.as_str()).collect();
    assert!(
        callers.iter().any(|p| p.ends_with("agent.lua")),
        "a dofile-aliased dotted call must resolve: {callers:?}"
    );
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn js_extraction_finds_functions_classes_imports_and_calls() {
    // The WhatsApp pipeline is JavaScript; before this the graph could not see the files the
    // agent actually edits (`.mjs`/`.cjs`/`.js` produced no nodes at all).
    let src = r#"
const fs = require('node:fs');
import { helper } from './helper.mjs';
import * as store from './store.mjs';
export function greet(name) { return helper(name); }
const build = (x) => format(x);
class Reader { read() { store.load(fs.readFileSync('x')); } }
module.exports = { greet };
"#;
    let ex = extract("scripts/whatsapp-read.mjs", "javascript", src);
    let names: Vec<&str> = ex.nodes.iter().map(|n| n.name.as_str()).collect();
    assert!(names.contains(&"greet"), "{names:?}");
    assert!(names.contains(&"build"), "{names:?}");
    assert!(names.contains(&"Reader"), "{names:?}");
    assert!(names.contains(&"read"), "{names:?}");
    assert!(
        ex.imports.iter().any(|i| i.alias == "fs" && i.module == "node:fs"),
        "{:?}",
        ex.imports
    );
    assert!(
        ex.imports.iter().any(|i| i.alias == "helper" && i.module == "./helper.mjs"),
        "{:?}",
        ex.imports
    );
    assert!(
        ex.imports.iter().any(|i| i.alias == "store" && i.module == "./store.mjs"),
        "{:?}",
        ex.imports
    );
    assert!(ex.edges.iter().any(|e| e.kind == "imports" && e.target == "node:fs"));
    assert!(ex.edges.iter().any(|e| e.kind == "calls" && e.target == "helper"));
    assert!(ex.edges.iter().any(|e| e.kind == "calls" && e.target == "format"));
    assert!(ex.edges.iter().any(|e| e.kind == "calls" && e.target == "store.load"));
}

#[test]
fn a_js_namespace_import_resolves_a_dotted_call() {
    // `import * as reply from './reply.mjs'` then `reply.buildReply()` must reach the definition
    // in reply.mjs, the same way a Lua `require` alias does.
    let dir = temp_dir("js-alias");
    std::fs::create_dir_all(dir.join("scripts")).unwrap();
    std::fs::write(
        dir.join("scripts/reply.mjs"),
        "export function buildReply() { return 1; }\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("scripts/run.mjs"),
        "import * as reply from './reply.mjs';\nexport function main() { return reply.buildReply(); }\n",
    )
    .unwrap();
    let db = dir.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    store.index(&dir, false).unwrap();

    let rows = store.explain("buildReply").unwrap();
    let def = rows
        .iter()
        .find(|(n, _, _)| n.name == "buildReply")
        .expect("buildReply is defined");
    let callers: Vec<&str> = def.2.iter().map(|e| e.path.as_str()).collect();
    assert!(
        callers.iter().any(|p| p.ends_with("run.mjs")),
        "a namespace-imported dotted call must resolve: {callers:?}"
    );
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn a_dotted_call_on_an_unknown_receiver_does_not_land_on_a_local() {
    // `response.text()` has no import alias and is not `self`/`this`/`M`, so there is no definition
    // to reach and the edge stays unresolved - it must not resolve to the local `text`.
    let dir = temp_dir("js-unknown-receiver");
    std::fs::write(
        dir.join("run.mjs"),
        "const text = 1;\nexport function go() { return response.text(); }\n",
    )
    .unwrap();
    let db = dir.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    store.index(&dir, false).unwrap();

    let rows = store.explain("text").unwrap();
    let def = rows
        .iter()
        .find(|(n, _, _)| n.name == "text")
        .expect("the local text exists");
    let incoming: Vec<String> = def.2.iter().map(|e| e.target.clone()).collect();
    assert!(
        !incoming.iter().any(|t| t == "response.text"),
        "response.text must not resolve to a local: {incoming:?}"
    );
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn this_member_resolves_within_the_file() {
    // `this.foo()` names the method in the same file; the receiver has no name of its own to match.
    let dir = temp_dir("js-this");
    std::fs::write(
        dir.join("run.mjs"),
        "export class C {\n  foo() { return 1; }\n  bar() { return this.foo(); }\n}\n",
    )
    .unwrap();
    let db = dir.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    store.index(&dir, false).unwrap();

    let rows = store.explain("foo").unwrap();
    let def = rows
        .iter()
        .find(|(n, _, _)| n.name == "foo")
        .expect("method foo exists");
    assert!(
        def.2.iter().any(|e| e.path.ends_with("run.mjs")),
        "this.foo must resolve to the method: {:?}",
        def.2.iter().map(|e| e.target.clone()).collect::<Vec<_>>()
    );
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn ranked_search_returns_a_source_ready_symbol_and_exact_definition() {
    let dir = temp_dir("symbol-source");
    let source = "fn helper() -> i32 { 1 }\n\nfn route_handler(request: &str) -> usize {\n    helper() as usize + request.len()\n}\n\nfn unrelated() {}\n";
    std::fs::write(dir.join("router.rs"), source).unwrap();
    let db = dir.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    store.index(&dir, false).unwrap();

    let hits = store.search_symbols("route handler", 5).unwrap();
    assert!(!hits.is_empty());
    assert_eq!(hits[0].node.name, "route_handler");
    assert_eq!(hits[0].confidence, "high");
    assert_eq!(hits[0].matched_terms, vec!["route", "handler"]);

    let selected = &hits[0].node;
    let value = store.symbol_source_json(
        &selected.path, &selected.name, selected.line, Some(&selected.kind), 0, 24_000,
    ).unwrap();
    let returned = value["source"].as_str().unwrap();
    assert!(returned.starts_with("fn route_handler"), "{returned}");
    assert!(returned.contains("request.len()"), "{returned}");
    assert!(!returned.contains("fn unrelated"), "{returned}");
    assert_eq!(value["freshness"], "verified_snapshot");
    assert_eq!(value["eof"], true);
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn symbol_source_pages_large_utf8_definitions_without_splitting_characters() {
    let dir = temp_dir("symbol-page");
    std::fs::write(dir.join("text.lua"), "local function render()\n  return 'olá mundo'\nend\n").unwrap();
    let db = dir.join("graph.db");
    let mut store = Store::open(&db).unwrap();
    store.index(&dir, false).unwrap();
    let hit = store.search_symbols("render", 1).unwrap().remove(0).node;

    let first = store.symbol_source_json(&hit.path, &hit.name, hit.line, Some(&hit.kind), 0, 35).unwrap();
    let next = first["next_byte_offset"].as_u64().expect("first page continues") as usize;
    let second = store.symbol_source_json(&hit.path, &hit.name, hit.line, Some(&hit.kind), next, 35).unwrap();
    let joined = format!("{}{}", first["source"].as_str().unwrap(), second["source"].as_str().unwrap());
    assert!(joined.contains("olá mundo"), "{joined}");
    assert_eq!(second["eof"], true);
    std::fs::remove_dir_all(&dir).ok();
}
