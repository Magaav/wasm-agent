//! `host.graph_*` — the code graph as a capability.
//!
//! The graph is built by the `wa-graph` crate and stored beside the ledger. Reads verify the
//! complete source snapshot; a stale graph is synchronously refreshed or rejected. A Lua run can
//! ask "who calls `append_turn`" without a
//! grep-and-read round trip, and a `host.*` reference is a typed edge to a capability node.

use crate::lua::{arg_string, lua_pushlstring, LuaState};
use serde_json::{json, Value};
use std::ffi::c_char;
use std::path::PathBuf;
use std::sync::OnceLock;

struct Config {
    root: PathBuf,
    db: PathBuf,
}

static CONFIG: OnceLock<Config> = OnceLock::new();

/// Resolve the graph location once, at node startup. Root defaults to the runtime worktree (the
/// node's cwd), which is the source the agent is actually running from.
pub fn configure(root: PathBuf, db: PathBuf) {
    let _ = CONFIG.set(Config { root, db });
}

fn push_json(l: *mut LuaState, value: &Value) {
    let text = serde_json::to_string(value).unwrap_or_else(|_| "null".to_string());
    unsafe { lua_pushlstring(l, text.as_ptr() as *const c_char, text.len()) };
}

/// An optional options argument, passed as a JSON object string. Absent or malformed is `null`.
fn json_arg(l: *mut LuaState, index: std::ffi::c_int) -> Value {
    arg_string(l, index)
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or(Value::Null)
}

fn opt_str(options: &Value, key: &str) -> Option<String> {
    options
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
        .filter(|s| !s.is_empty())
}

fn db_for(options: &Value) -> Result<PathBuf, String> {
    opt_str(options, "db")
        .map(PathBuf::from)
        .or_else(|| CONFIG.get().map(|config| config.db.clone()))
        .ok_or_else(|| "graph_not_configured".to_string())
}

fn root_for(options: &Value) -> Result<PathBuf, String> {
    opt_str(options, "root")
        .map(PathBuf::from)
        .or_else(|| CONFIG.get().map(|config| config.root.clone()))
        .ok_or_else(|| "graph_not_configured".to_string())
}

fn read(
    l: *mut LuaState,
    options_index: std::ffi::c_int,
    body: impl Fn(&wa_graph::Store, &Value) -> Result<Value, String>,
) -> std::ffi::c_int {
    let options = json_arg(l, options_index);
    let outcome = (|| -> Result<Value, String> {
        let root = root_for(&options)?;
        let db = db_for(&options)?;
        for _ in 0..3 {
            if let Ok(store) = wa_graph::Store::open_readonly(&db) {
                store.begin_read().map_err(|e| e.to_string())?;
                let fresh = store.verify_snapshot(&root).map_err(|e| e.to_string())?;
                if fresh {
                    let answer = body(&store, &options)?;
                    let still_fresh = store.verify_snapshot(&root).map_err(|e| e.to_string())?;
                    store.end_read().map_err(|e| e.to_string())?;
                    if still_fresh {
                        return Ok(answer);
                    }
                }
            }
            let mut writer = wa_graph::Store::open(&db).map_err(|e| e.to_string())?;
            // A stale or legacy snapshot may have missing source records. Rebuild all
            // records rather than trusting the old incremental stamps to repair them.
            writer.index(&root, true).map_err(|e| e.to_string())?;
        }
        Err("graph_source_unstable: use read/grep and retry later".into())
    })();
    push_json(
        l,
        &outcome.unwrap_or_else(|error| json!({ "error": error })),
    );
    1
}

/// host.graph_index(opts_json?) -> {ok, indexed, unchanged, removed, nodes, edges, ...} | {error}
///
/// Build or refresh the graph. Incremental by content hash, so a repeat call with nothing changed
/// reparses nothing. `{ "root": "...", "force": true }` overrides the configured location.
pub extern "C" fn graph_index(l: *mut LuaState) -> std::ffi::c_int {
    let options = json_arg(l, 1);
    let outcome = (|| -> Result<Value, String> {
        let root = root_for(&options)?;
        let db = db_for(&options)?;
        let force = options
            .get("force")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let mut store = wa_graph::Store::open(&db).map_err(|e| e.to_string())?;
        let report = store.index(&root, force).map_err(|e| e.to_string())?;
        Ok(json!({
            "ok": true,
            "indexed": report.indexed,
            "unchanged": report.unchanged,
            "removed": report.removed,
            "nodes": report.nodes,
            "edges": report.edges,
            "resolved": report.resolved,
            "unresolved": report.unresolved,
            "root": root.to_string_lossy(),
            "db": db.to_string_lossy(),
        }))
    })();
    push_json(
        l,
        &outcome.unwrap_or_else(|error| json!({ "error": error })),
    );
    1
}

/// host.graph_query(text, opts_json?) -> [ {kind,name,path,line,detail} ] | {error}
pub extern "C" fn graph_query(l: *mut LuaState) -> std::ffi::c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    read(l, 2, |store, options| {
        let limit = options
            .get("limit")
            .and_then(Value::as_i64)
            .unwrap_or(50)
            .clamp(1, 500);
        store.query_json(&text, limit).map_err(|e| e.to_string())
    })
}

/// host.graph_explain(name, opts_json?) -> [ {node, outgoing, incoming} ] | {error}
pub extern "C" fn graph_explain(l: *mut LuaState) -> std::ffi::c_int {
    let name = arg_string(l, 1).unwrap_or_default();
    read(l, 2, |store, _| {
        store.explain_json(&name).map_err(|e| e.to_string())
    })
}

/// host.graph_path(from, to, opts_json?) -> [ {kind,name,path,line,via} ] | null | {error}
pub extern "C" fn graph_path(l: *mut LuaState) -> std::ffi::c_int {
    let from = arg_string(l, 1).unwrap_or_default();
    let to = arg_string(l, 2).unwrap_or_default();
    read(l, 3, |store, _| {
        store.path_json(&from, &to).map_err(|e| e.to_string())
    })
}

/// host.graph_caps(opts_json?) -> [ {capability, uses} ] | {error}
pub extern "C" fn graph_caps(l: *mut LuaState) -> std::ffi::c_int {
    read(l, 1, |store, _| {
        store.caps_json().map_err(|e| e.to_string())
    })
}

/// host.graph_stats(opts_json?) -> {files,nodes,edges,resolved,unresolved,byKind} | {error}
pub extern "C" fn graph_stats(l: *mut LuaState) -> std::ffi::c_int {
    read(l, 1, |store, _| {
        store
            .stats()
            .map(|stats| stats.to_json())
            .map_err(|e| e.to_string())
    })
}

/// host.graph_status(opts_json?) -> {root, db, ready} | {error}
///
/// `ready` means the graph matches every indexed file's current bytes, not merely that a DB exists.
pub extern "C" fn graph_status(l: *mut LuaState) -> std::ffi::c_int {
    let options = json_arg(l, 1);
    let outcome = (|| -> Result<Value, String> {
        let root = root_for(&options)?;
        let db = db_for(&options)?;
        let ready = if db.exists() {
            let store = wa_graph::Store::open_readonly(&db).map_err(|e| e.to_string())?;
            store.verify_snapshot(&root).map_err(|e| e.to_string())?
        } else {
            false
        };
        Ok(json!({
            "root": root.to_string_lossy(),
            "db": db.to_string_lossy(),
            "ready": ready,
        }))
    })();
    push_json(
        l,
        &outcome.unwrap_or_else(|error| json!({ "error": error })),
    );
    1
}
