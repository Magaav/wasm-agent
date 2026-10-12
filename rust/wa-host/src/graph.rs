//! `host.graph_*` — the code graph as a capability.
//!
//! The graph is built by `wa-graph` and stored beside the ledger. Admission reconciles
//! source content and waits for a root-isolated atomic publication covering its frozen
//! revision; reads then pin a read-only snapshot. Explicit index still supports full rebuilds.
//! A Lua run can
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

#[cfg(test)]
#[path = "graph_tests.rs"]
mod tests;

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

// Select root and DB together. Workspace caches are on-demand and the shared
// coordinator never lets one root replace another root's derived snapshot.
fn locations(options: &Value, config: Option<&Config>) -> Result<(PathBuf, PathBuf), String> {
    let root = opt_str(options, "root").map(PathBuf::from)
        .or_else(|| config.map(|c| c.root.clone()))
        .ok_or_else(|| "graph_not_configured".to_string())?;
    let root = root.canonicalize().map_err(|e| format!("graph_root_unavailable: {e}"))?;
    if !root.is_dir() {return Err("graph_root_not_directory".into());}
    if let Some(db) = opt_str(options, "db") {return Ok((root, PathBuf::from(db)));}
    let config = config.ok_or_else(|| "graph_not_configured".to_string())?;
    let identity = |path: &std::path::Path| {
        let text = path.to_string_lossy().into_owned();
        if cfg!(windows) {text.to_lowercase()} else {text}
    };
    let same = config.root.canonicalize().ok().map(|p| identity(&p) == identity(&root)).unwrap_or(false);
    let db = if same {config.db.clone()} else {
        let digest = ring::digest::digest(&ring::digest::SHA256, identity(&root).as_bytes());
        let key: String = digest.as_ref().iter().map(|byte| format!("{byte:02x}")).collect();
        config.db.with_extension("roots").join(format!("{key}.db"))
    };
    Ok((root, db))
}

fn read_snapshot(
    root: &std::path::Path,
    db: &std::path::Path,
    options: &Value,
    body: impl Fn(&wa_graph::Store, &Value, &std::path::Path) -> Result<Value, String>,
) -> Result<Value, String> {
    let started = std::time::Instant::now();
    let timeout=options.get("wait_ms").and_then(Value::as_u64).unwrap_or(60_000).clamp(1,120_000);
    let deadline=started+std::time::Duration::from_millis(timeout);
    let manager=wa_graph::coordinator::shared();let entry=manager.entry(root,db)?;
    let required=match manager.admit_until(&entry,false,Some(deadline),&mut |_,_|crate::serve::beat()) {
        Ok(revision)=>revision,
        Err(error)=>{let mut status=entry.status();status["error"]=json!(error);status["required_revision"]=Value::Null;status["capture_required"]=json!(true);status["next"]=json!("Content capture failed; use read/grep and inspect the affected root. No stale answer was returned.");return Ok(status);}
    };
    let (store,mut meta)=match entry.snapshot(required,deadline,&mut |_|crate::serve::beat()) {Ok(snapshot)=>snapshot,Err(error)=>return Ok(error)};
    let generation=store.generation().map_err(|e|e.to_string())?;
    let mut captured_options=options.clone();
    // Budgeted views account for revision metadata inside their whole-response pager.
    // Root/generation already exist there; do not crowd out exact rows with duplicate status.
    captured_options["_graph_snapshot"]=json!({"required_revision":meta["required_revision"],"committed_revision":meta["committed_revision"],"wait_ms":meta["wait_ms"]});
    let answer=body(&store,&captured_options,root);
    store.end_read().map_err(|e|e.to_string())?;
    meta["read_ms"]=json!(started.elapsed().as_millis());meta["generation"]=json!(generation);
    let mut answer=match answer {Ok(value)=>value,Err(error)=>{meta["error"]=json!(error);meta["next"]=json!("Inspect the selector/request and revision evidence; use read/grep. No source answer was returned.");return Ok(meta);}};
    if answer.is_object(){if answer.get("graph_snapshot").is_none(){answer["graph_snapshot"]=meta;}}else if options.get("with_snapshot").and_then(Value::as_bool).unwrap_or(false){answer=json!({"items":answer,"graph_snapshot":meta});}
    Ok(answer)
}

fn read(
    l: *mut LuaState,
    options_index: std::ffi::c_int,
    body: impl Fn(&wa_graph::Store, &Value, &std::path::Path) -> Result<Value, String>,
) -> std::ffi::c_int {
    let options = json_arg(l, options_index);
    let outcome = locations(&options, CONFIG.get())
        .and_then(|(root, db)| read_snapshot(&root, &db, &options, body));
    push_json(l, &outcome.unwrap_or_else(|error| json!({ "error": error })));
    1
}

/// host.graph_index(opts_json?) -> {ok, indexed, unchanged, removed, nodes, edges, ...} | {error}
///
/// Build or refresh the graph. Incremental by content hash, so a repeat call with nothing changed
/// reparses nothing. `{ "root": "...", "force": true }` overrides the configured location.
pub extern "C-unwind" fn graph_index(l: *mut LuaState) -> std::ffi::c_int {
    let options = json_arg(l, 1);
    let outcome = (|| -> Result<Value, String> {
        let (root, db) = locations(&options, CONFIG.get())?;
        let force = options
            .get("force")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let manager=wa_graph::coordinator::shared();let entry=manager.entry(&root,&db)?;
        let started=std::time::Instant::now();let before=entry.status();
        let required=manager.admit_until(&entry,force,Some(started+std::time::Duration::from_secs(120)),&mut |_,_|crate::serve::beat())?;
        let (store,meta)=match entry.snapshot(required,started+std::time::Duration::from_secs(120),&mut |_|crate::serve::beat()){Ok(value)=>value,Err(error)=>return Ok(error)};
        let no_work=!force && before["committed_revision"].as_u64().unwrap_or(0)>=required;
        let stats=store.stats().map_err(|e|e.to_string())?;
        let indexed=if no_work{json!(0)}else{meta["work"]["parsed"].clone()};
        let unchanged=if no_work{json!(stats.files)}else{meta["work"]["unchanged"].clone()};
        let removed=if no_work{json!(0)}else{meta["work"]["removed"].clone()};
        let examined=if no_work{json!(0)}else{meta["work"]["re_resolved"].clone()};
        let nodes=if no_work{json!(0)}else{meta["work"]["nodes"].clone()};
        let edges=if no_work{json!(0)}else{meta["work"]["edges"].clone()};
        store.end_read().map_err(|e|e.to_string())?;
        Ok(json!({"ok":true,"indexed":indexed,"unchanged":unchanged,"removed":removed,"re_resolved":examined,"nodes":nodes,"edges":edges,"resolved":stats.resolved,"unresolved":stats.unresolved,"root":root,"db":db,"graph_snapshot":meta}))
    })();
    push_json(
        l,
        &outcome.unwrap_or_else(|error| json!({ "error": error })),
    );
    1
}

/// host.graph_query(text, opts_json?) -> [ {kind,name,path,line,detail} ] | {error}
pub extern "C-unwind" fn graph_query(l: *mut LuaState) -> std::ffi::c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    read(l, 2, |store, options, _| {
        let limit = options
            .get("limit")
            .and_then(Value::as_i64)
            .unwrap_or(50)
            .clamp(1, 500);
        store.query_json(&text, limit).map_err(|e| e.to_string())
    })
}

/// host.graph_search(text, opts_json?) -> ranked symbol selectors with confidence evidence.
pub extern "C-unwind" fn graph_search(l: *mut LuaState) -> std::ffi::c_int {
    let text = arg_string(l, 1).unwrap_or_default();
    read(l, 2, |store, options, _| {
        let limit = options
            .get("limit")
            .and_then(Value::as_i64)
            .unwrap_or(12)
            .clamp(1, 100);
        let prefer_implementations = options.get("prefer_implementations")
            .and_then(Value::as_bool).unwrap_or(false);
        store
            .search_symbols_json_with_preference(&text, limit, prefer_implementations)
            .map_err(|e| e.to_string())
    })
}

/// host.graph_source(opts_json) -> an exact, bounded page of one indexed definition.
fn source(store:&wa_graph::Store, options:&Value)->Result<Value,String>{
    let path=options.get("path").and_then(Value::as_str).ok_or("path_required")?;
    let name=options.get("name").and_then(Value::as_str).ok_or("name_required")?;
    let line=options.get("line").and_then(Value::as_i64).filter(|line|*line>0).ok_or("line_required")?;
    let kind=options.get("kind").and_then(Value::as_str).filter(|kind|!kind.is_empty());
    let offset=options.get("byte_offset").and_then(Value::as_u64).unwrap_or(0) as usize;
    let max_bytes=options.get("max_bytes").and_then(Value::as_u64).unwrap_or(20_000).clamp(256,20_000) as usize;
    let answer=store.symbol_source_json(path,name,line,kind,offset,max_bytes).map_err(|e|e.to_string())?;
    if options.get("source_version").and_then(Value::as_str).map_or(false,|expected|answer["source_version"].as_str()!=Some(expected)){return Err("symbol_source_changed".into());}
    Ok(answer)
}
/// One root, admission revision and pinned SQLite snapshot for every selector.
pub extern "C-unwind" fn graph_sources(l:*mut LuaState)->std::ffi::c_int{
    read(l,1,|store,options,_|{
        let requests=options.get("requests").and_then(Value::as_array).filter(|a|!a.is_empty()&&a.len()<=8).ok_or("requests_required_1_to_8")?;
        let results:Vec<_>=requests.iter().map(|request|source(store,request).unwrap_or_else(|error|json!({"error":error}))).collect();
        let failed=results.iter().filter(|item|item.get("error").is_some()).count();
        Ok(json!({"ok":failed==0,"failed":failed,"succeeded":requests.len()-failed,"results":results}))
    })
}
pub(crate) fn native_write(path:&str){
    wa_graph::coordinator::notify_known_path(std::path::Path::new(path));
}

pub extern "C-unwind" fn graph_notify(l:*mut LuaState)->std::ffi::c_int{
    let options=json_arg(l,1);
    let outcome=(||->Result<Value,String>{
        if let Some(path)=opt_str(&options,"path"){
            if wa_graph::extract::language_for(&path).is_none(){return Ok(json!({"ok":true,"queued":false,"reason":"not_indexable_source"}));}
            let (root,db)=locations(&options,CONFIG.get())?;
            let target=PathBuf::from(path).canonicalize().map_err(|e|format!("graph_edit_path_unavailable:{e}"))?;
            let relative=match target.strip_prefix(&root){Ok(path)=>path,Err(_)=>return Ok(json!({"ok":true,"queued":false,"reason":"outside_indexed_root"}))};
            if relative.components().any(|part|matches!(part.as_os_str().to_str(),Some(".git"|"target"|"node_modules"|".wa-graph"|"releases"|".orca-worktree-trash"))){return Ok(json!({"ok":true,"queued":false,"reason":"excluded_source_directory"}));}
            wa_graph::coordinator::shared().notify(&root,&db)?;
        }else{let (root,db)=locations(&options,CONFIG.get())?;wa_graph::coordinator::shared().notify(&root,&db)?;}
        Ok(json!({"ok":true,"queued":true}))
    })();
    push_json(l,&outcome.unwrap_or_else(|error|json!({"error":error})));1
}
pub extern "C-unwind" fn graph_source(l: *mut LuaState) -> std::ffi::c_int {
    read(l,1,|store,options,_|source(store,options))
}

/// host.graph_explain(name, opts_json?) -> [ {node, outgoing, incoming} ] | {error}
pub extern "C-unwind" fn graph_explain(l: *mut LuaState) -> std::ffi::c_int {
    let name = arg_string(l, 1).unwrap_or_default();
    read(l, 2, |store, _, _| {
        store.explain_json(&name).map_err(|e| e.to_string())
    })
}

/// host.graph_path(from, to, opts_json?) -> [ {kind,name,path,line,via} ] | null | {error}
pub extern "C-unwind" fn graph_path(l: *mut LuaState) -> std::ffi::c_int {
    let from = arg_string(l, 1).unwrap_or_default();
    let to = arg_string(l, 2).unwrap_or_default();
    read(l, 3, |store, _, _| {
        store.path_json(&from, &to).map_err(|e| e.to_string())
    })
}

/// host.graph_caps(opts_json?) -> [ {capability, uses} ] | {error}
pub extern "C-unwind" fn graph_caps(l: *mut LuaState) -> std::ffi::c_int {
    read(l, 1, |store, _, _| {
        store.caps_json().map_err(|e| e.to_string())
    })
}

/// host.graph_stats(opts_json?) -> {files,nodes,edges,resolved,unresolved,byKind} | {error}
pub extern "C-unwind" fn graph_stats(l: *mut LuaState) -> std::ffi::c_int {
    read(l, 1, |store, _, _| {
        store
            .stats()
            .map(|stats| stats.to_json())
            .map_err(|e| e.to_string())
    })
}

/// host.graph_overview(opts_json?) -> bounded architecture sections with exact totals.
pub extern "C-unwind" fn graph_overview(l: *mut LuaState) -> std::ffi::c_int {
    read(l, 1, |store, options, _| {
        let aspects = options
            .get("aspects")
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_else(Vec::new);
        let mut limit = options
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(8)
            .clamp(1, 50);
        let max_bytes = options
            .get("max_bytes")
            .and_then(Value::as_u64)
            .unwrap_or(24_000)
            .clamp(2_048, 200_000) as usize;
        loop {
            let mut value = store
                .architecture_json(&aspects, limit as usize)
                .map_err(|e| e.to_string())?;
            value["graph_snapshot"]=options["_graph_snapshot"].clone();
            if serde_json::to_vec(&value).map_err(|e| e.to_string())?.len() <= max_bytes {
                return Ok(value);
            }
            if limit == 1 {
                return Err("overview_budget_too_small".into());
            }
            limit -= 1;
        }
    })
}

/// host.graph_impact(request_json) -> changed definitions and bounded transitive impact evidence.
pub extern "C-unwind" fn graph_impact(l: *mut LuaState) -> std::ffi::c_int {
    read(l, 1, |store, request, root| {
        store.impact_json(root, request).map_err(|e| e.to_string())
    })
}

/// host.graph_status(opts_json?) -> {root, db, ready} | {error}
///
/// `ready` means the graph matches every indexed file's current bytes, not merely that a DB exists.
pub extern "C-unwind" fn graph_status(l: *mut LuaState) -> std::ffi::c_int {
    let options = json_arg(l, 1);
    let outcome = (|| -> Result<Value, String> {
        let (root, db) = locations(&options, CONFIG.get())?;
        let ready = if db.exists() {
            let store = wa_graph::Store::open_readonly(&db).map_err(|e| e.to_string())?;
            store.verify_snapshot(&root).map_err(|e| e.to_string())?
        } else {
            false
        };
        let entry=wa_graph::coordinator::shared().entry(&root,&db)?;
        let mut status=entry.status();status["ready"]=json!(ready && status["dirty_hint"]!=true && status["queued"]!=true && status["active"]!=true);Ok(status)
    })();
    push_json(
        l,
        &outcome.unwrap_or_else(|error| json!({ "error": error })),
    );
    1
}

/// host.graph_patch_audit(request_json) -> review leads or an explicit error.
/// Like navigation, audit captures a required revision and reads one pinned committed snapshot.
pub extern "C-unwind" fn graph_patch_audit(l: *mut LuaState) -> std::ffi::c_int {
    read(l, 1, |store, request, root| {
        let mut report = store.audit_json(root, request).map_err(|e| e.to_string())?;
        let (_, db) = locations(request, CONFIG.get())?;
        report["root"] = json!(root.to_string_lossy());
        report["db_bytes"] = json!(std::fs::metadata(db).map_err(|e| e.to_string())?.len());
        Ok(report)
    })
}
