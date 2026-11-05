//! The code graph as a WASI component: MCP over stdin/stdout, one request per run.
//!
//! The kernel mounts the indexed root read-only at `/graph/root` and a private database directory
//! read-write at `/graph/db`, and serializes calls per database. Every call admits content first
//! (capture the root, compare with the committed manifest, index what changed as a new revision),
//! then reads one pinned snapshot, so an answer is never older than the bytes on disk when the call
//! began. Scheduling (edit hints, OS watcher, background refresh) stays in the kernel
//! (rust/wa-host/src/graph.rs); everything that parses, stores or answers is here.
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use wa_graph::incremental::Manifest;
use wa_graph::Store;

const ROOT: &str = "/graph/root";
const DB_DIR: &str = "/graph/db";

fn main() {
    let mut out = std::io::stdout();
    let mut ready = false;
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        let method = message["method"].as_str().unwrap_or("");
        if method == "notifications/initialized" {
            ready = true;
            continue;
        }
        let Some(id) = message.get("id").cloned() else { continue };
        let result = match method {
            "initialize" => json!({"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"graph","version":env!("CARGO_PKG_VERSION")}}),
            "tools/list" if ready => json!({"tools": tools()}),
            "tools/call" if ready => {
                let name = message["params"]["name"].as_str().unwrap_or("");
                let args = message["params"]["arguments"].clone();
                let data = call(name, &args).unwrap_or_else(|error| json!({"error": error}));
                json!({"content":[{"type":"text","text":data.to_string()}],"structuredContent":data,"isError":false})
            }
            _ => {
                let _ = writeln!(out, "{}", json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"Method not found"}}));
                continue;
            }
        };
        let _ = writeln!(out, "{}", json!({"jsonrpc":"2.0","id":id,"result":result}));
        let _ = out.flush();
    }
}

fn tool(name: &str, description: &str, required: &[&str]) -> Value {
    let mut properties = serde_json::Map::new();
    for key in required {
        properties.insert((*key).into(), json!({"type":"string"}));
    }
    json!({"name":name,"description":description,
        "inputSchema":{"type":"object","properties":properties,"required":required,"additionalProperties":true}})
}

fn tools() -> Value {
    json!([
        tool("index", "Build or refresh the graph (content-hashed; force=true rebuilds)", &[]),
        tool("query", "Where a name appears", &["text"]),
        tool("search", "Ranked definitions for a concept or identifier", &["text"]),
        tool("source", "Exact bounded source of one definition (path, name, line)", &[]),
        tool("sources", "Exact source of up to 8 definitions from one snapshot (requests)", &[]),
        tool("explain", "What a symbol is, what it uses, who uses it", &["name"]),
        tool("path", "Shortest direction-of-use path between two symbols", &["from", "to"]),
        tool("caps", "Which code calls which host capability", &[]),
        tool("stats", "Index size counters", &[]),
        tool("overview", "Bounded structural overview of the indexed tree", &[]),
        tool("impact", "Callers/dependencies of changed definitions at a depth", &[]),
        tool("patch_audit", "Which symbols a changeset reaches", &[]),
        tool("status", "Whether the committed graph matches every indexed file's current bytes", &[]),
    ])
}

fn db_path(args: &Value) -> PathBuf {
    let file = args.get("db_file").and_then(Value::as_str).filter(|f| !f.is_empty() && !f.contains(['/', '\\'])).unwrap_or("graph.db");
    Path::new(DB_DIR).join(file)
}

fn s(error: impl std::fmt::Display) -> String {
    error.to_string()
}

/// The common snapshot evidence, same field names the native coordinator reported.
fn meta(root: &Path, db: &Path, required: u64, committed: u64, work: &Value, reused: bool, started: Instant) -> Value {
    json!({"root":root,"db":db,"workspace_revision":required,"committed_revision":committed,"required_revision":required,
        "reused_committed_snapshot":reused,"wait_ms":started.elapsed().as_millis() as u64,"work":work,
        "capture_domain":"supported_utf8_sources","queued":false,"active":false,"dirty_hint":false,"failure":Value::Null})
}

enum Admit {
    Ready { required: u64, work: Value, reused: bool, skipped: Vec<String> },
    Failed(Value),
}

/// Capture → compare → index changed files as revision committed+1. Stateless: the database is the
/// only memory between calls (the kernel holds the per-database lock around the whole call).
fn admit(root: &Path, db: &Path, force: bool, deadline: Instant, started: Instant) -> Result<Admit, String> {
    let committed = if db.exists() { Store::open_readonly(db).and_then(|store| store.committed_revision()).map_err(s)? } else { 0 };
    let manifest = match Manifest::capture_until(root, Some(deadline), &mut |_, _| {}) {
        Ok(manifest) => manifest,
        Err(error) => {
            let mut status = meta(root, db, committed, committed, &Value::Null, false, started);
            status["error"] = json!(format!("graph_capture_failed: {error}"));
            status["required_revision"] = Value::Null;
            status["capture_required"] = json!(true);
            status["next"] = json!("Content capture failed; use read/grep and inspect the affected root. No stale answer was returned.");
            return Ok(Admit::Failed(status));
        }
    };
    if !force && db.exists() {
        let cache = Store::open_readonly(db).map_err(s)?;
        cache.begin_read().map_err(s)?;
        let fresh = cache.manifest_fingerprint().map_err(s)?.as_deref() == Some(manifest.fingerprint.as_str()) && cache.matches_manifest(&manifest).map_err(s)?;
        cache.end_read().map_err(s)?;
        if fresh {
            let work = json!({"revision":committed,"parsed":0,"unchanged":manifest.files.len(),"removed":0,"re_resolved":0,"nodes":0,"edges":0});
            return Ok(Admit::Ready { required: committed, work, reused: true, skipped: manifest.skipped_non_utf8 });
        }
    }
    let revision = committed + 1;
    let report = Store::open(db).and_then(|mut store| store.index_manifest(&manifest, force, revision, &mut |_, _| {}));
    match report {
        Ok(report) => {
            let work = json!({"revision":revision,"parsed":report.indexed,"unchanged":report.unchanged,"removed":report.removed,"re_resolved":report.re_resolved,
                "nodes":report.nodes,"edges":report.edges,"resolved":report.resolved,"unresolved":report.unresolved});
            Ok(Admit::Ready { required: revision, work, reused: false, skipped: manifest.skipped_non_utf8 })
        }
        Err(error) => {
            let mut status = meta(root, db, revision, committed, &Value::Null, false, started);
            status["failure"] = json!([revision, error.to_string()]);
            status["error"] = json!(format!("graph_index_failed: {error}"));
            status["next"] = json!("Use bounded read/grep now. Inspect failure/progress and repair its cause; graph action=index force=true deliberately retries a failed derived index. No stale answer was returned.");
            Ok(Admit::Failed(status))
        }
    }
}

fn deadline_of(args: &Value, default_ms: u64) -> Instant {
    Instant::now() + Duration::from_millis(args.get("wait_ms").and_then(Value::as_u64).unwrap_or(default_ms).clamp(1, 120_000))
}

/// Admit, then run `body` on one pinned read snapshot; the answer carries `graph_snapshot`.
fn read(args: &Value, body: impl Fn(&Store, &Value, &Path) -> Result<Value, String>) -> Result<Value, String> {
    let started = Instant::now();
    let root = Path::new(ROOT);
    let db = db_path(args);
    let (required, work, reused, skipped) = match admit(root, &db, false, deadline_of(args, 60_000), started)? {
        Admit::Ready { required, work, reused, skipped } => (required, work, reused, skipped),
        Admit::Failed(status) => return Ok(status),
    };
    let store = Store::open_readonly(&db).map_err(s)?;
    store.begin_read().map_err(s)?;
    let committed = store.committed_revision().map_err(s)?;
    let mut snapshot = meta(root, &db, required, committed, &work, reused, started);
    snapshot["skipped_non_utf8"] = json!(skipped);
    if committed < required {
        snapshot["error"] = json!("graph_snapshot_revision_mismatch");
        return Ok(snapshot);
    }
    let generation = store.generation().map_err(s)?;
    let mut options = args.clone();
    options["_graph_snapshot"] = json!({"required_revision":required,"committed_revision":committed,"wait_ms":snapshot["wait_ms"]});
    let answer = body(&store, &options, root);
    store.end_read().map_err(s)?;
    snapshot["read_ms"] = json!(started.elapsed().as_millis() as u64);
    snapshot["generation"] = json!(generation);
    let mut answer = match answer {
        Ok(value) => value,
        Err(error) => {
            snapshot["error"] = json!(error);
            snapshot["next"] = json!("Inspect the selector/request and revision evidence; use read/grep. No source answer was returned.");
            return Ok(snapshot);
        }
    };
    if answer.is_object() {
        if answer.get("graph_snapshot").is_none() {
            answer["graph_snapshot"] = snapshot;
        }
    } else if args.get("with_snapshot").and_then(Value::as_bool).unwrap_or(false) {
        answer = json!({"items":answer,"graph_snapshot":snapshot});
    }
    Ok(answer)
}

fn source(store: &Store, options: &Value) -> Result<Value, String> {
    let path = options.get("path").and_then(Value::as_str).ok_or("path_required")?;
    let name = options.get("name").and_then(Value::as_str).ok_or("name_required")?;
    let line = options.get("line").and_then(Value::as_i64).filter(|line| *line > 0).ok_or("line_required")?;
    let kind = options.get("kind").and_then(Value::as_str).filter(|kind| !kind.is_empty());
    let offset = options.get("byte_offset").and_then(Value::as_u64).unwrap_or(0) as usize;
    let max_bytes = options.get("max_bytes").and_then(Value::as_u64).unwrap_or(20_000).clamp(256, 20_000) as usize;
    let answer = store.symbol_source_json(path, name, line, kind, offset, max_bytes).map_err(s)?;
    if options.get("source_version").and_then(Value::as_str).map_or(false, |expected| answer["source_version"].as_str() != Some(expected)) {
        return Err("symbol_source_changed".into());
    }
    Ok(answer)
}

fn text(args: &Value, key: &str) -> String {
    args.get(key).and_then(Value::as_str).unwrap_or_default().to_string()
}

fn call(name: &str, args: &Value) -> Result<Value, String> {
    match name {
        "index" => {
            let started = Instant::now();
            let root = Path::new(ROOT);
            let db = db_path(args);
            let force = args.get("force").and_then(Value::as_bool).unwrap_or(false);
            match admit(root, &db, force, started + Duration::from_secs(120), started)? {
                Admit::Failed(status) => Ok(status),
                Admit::Ready { required, work, reused, skipped } => {
                    let store = Store::open_readonly(&db).map_err(s)?;
                    let stats = store.stats().map_err(s)?;
                    let committed = store.committed_revision().map_err(s)?;
                    let mut snapshot = meta(root, &db, required, committed, &work, reused, started);
                    snapshot["skipped_non_utf8"] = json!(skipped);
                    let field = |key: &str| if reused { json!(0) } else { work[key].clone() };
                    Ok(json!({"ok":true,"indexed":field("parsed"),"unchanged":if reused {json!(stats.files)} else {work["unchanged"].clone()},
                        "removed":field("removed"),"re_resolved":field("re_resolved"),"nodes":field("nodes"),"edges":field("edges"),
                        "resolved":stats.resolved,"unresolved":stats.unresolved,"root":root,"db":db,"graph_snapshot":snapshot}))
                }
            }
        }
        "query" => {
            let text = text(args, "text");
            read(args, |store, options, _| {
                let limit = options.get("limit").and_then(Value::as_i64).unwrap_or(50).clamp(1, 500);
                store.query_json(&text, limit).map_err(s)
            })
        }
        "search" => {
            let text = text(args, "text");
            read(args, |store, options, _| {
                let limit = options.get("limit").and_then(Value::as_i64).unwrap_or(12).clamp(1, 100);
                let prefer = options.get("prefer_implementations").and_then(Value::as_bool).unwrap_or(false);
                store.search_symbols_json_with_preference(&text, limit, prefer).map_err(s)
            })
        }
        "source" => read(args, |store, options, _| source(store, options)),
        "sources" => read(args, |store, options, _| {
            let requests = options.get("requests").and_then(Value::as_array).filter(|a| !a.is_empty() && a.len() <= 8).ok_or("requests_required_1_to_8")?;
            let results: Vec<_> = requests.iter().map(|request| source(store, request).unwrap_or_else(|error| json!({"error":error}))).collect();
            let failed = results.iter().filter(|item| item.get("error").is_some()).count();
            Ok(json!({"ok":failed==0,"failed":failed,"succeeded":requests.len()-failed,"results":results}))
        }),
        "explain" => {
            let name = text(args, "name");
            read(args, |store, _, _| store.explain_json(&name).map_err(s))
        }
        "path" => {
            let (from, to) = (text(args, "from"), text(args, "to"));
            read(args, |store, _, _| store.path_json(&from, &to).map_err(s))
        }
        "caps" => read(args, |store, _, _| store.caps_json().map_err(s)),
        "stats" => read(args, |store, _, _| store.stats().map(|stats| stats.to_json()).map_err(s)),
        "overview" => read(args, |store, options, _| {
            let aspects: Vec<String> = options.get("aspects").and_then(Value::as_array)
                .map(|values| values.iter().filter_map(Value::as_str).map(str::to_string).collect()).unwrap_or_default();
            let mut limit = options.get("limit").and_then(Value::as_u64).unwrap_or(8).clamp(1, 50);
            let max_bytes = options.get("max_bytes").and_then(Value::as_u64).unwrap_or(24_000).clamp(2_048, 200_000) as usize;
            loop {
                let mut value = store.architecture_json(&aspects, limit as usize).map_err(s)?;
                value["graph_snapshot"] = options["_graph_snapshot"].clone();
                if serde_json::to_vec(&value).map_err(s)?.len() <= max_bytes {
                    return Ok(value);
                }
                if limit == 1 {
                    return Err("overview_budget_too_small".into());
                }
                limit -= 1;
            }
        }),
        "impact" => read(args, |store, request, root| store.impact_json(root, request).map_err(s)),
        "patch_audit" => read(args, |store, request, root| {
            let mut report = store.audit_json(root, request).map_err(s)?;
            report["root"] = json!(root.to_string_lossy());
            report["db_bytes"] = json!(std::fs::metadata(db_path(request)).map_err(s)?.len());
            Ok(report)
        }),
        "status" => {
            let db = db_path(args);
            let root = Path::new(ROOT);
            let (verified, committed) = if db.exists() {
                let store = Store::open_readonly(&db).map_err(s)?;
                (store.verify_snapshot(root).map_err(s)?, store.committed_revision().map_err(s)?)
            } else {
                (false, 0)
            };
            Ok(json!({"root":root,"db":db,"verified":verified,"workspace_revision":committed,"committed_revision":committed,"failure":Value::Null}))
        }
        other => Err(format!("unknown_graph_tool:{other}")),
    }
}
