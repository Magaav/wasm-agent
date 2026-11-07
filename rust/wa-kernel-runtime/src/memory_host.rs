//! The memory seam, served: `wa:memory` in a component, `memory.db` in the kernel.
//!
//! This is the other half of `sql_host`: it loads the installed `memory` component, hands it one
//! `wa:kernel/sql` session scoped by its manifest, calls one seam function, and turns the answer into
//! the JSON the core consumes. `lua/core/memory.lua` routes here when `WA_MEMORY_COMPONENT=1`
//! (`docs/MEMORY.md`); the native path stays the default.
//!
//! Three rules this module is the place for:
//!
//! 1. **The grant is the manifest's.** `SqlScope::from_manifest` reads the component's declared
//!    tables; a component that declares none can read nothing. The caller cannot widen it: the
//!    request carries operations, never a scope.
//! 2. **A wedged or broken component never takes the node with it.** The call has its own deadline
//!    (so does every statement, inside `sql_host`), and any failure answers `ok: false` with a
//!    reason the router logs before falling back to the native path. A trap is not a silent empty
//!    result: "the store is empty" and "the component did not answer" must never look the same.
//! 3. **The journal is the kernel's.** A mutation is replicated by a `journal` row whose `origin` is
//!    this node's identity, and a component never names itself (the same rule `wa:bus` applies to a
//!    publisher). So the component reports what it wrote and the kernel appends the entry; the
//!    origin arrives in the request from the caller that resolved it.
//!
//! Known gap, deliberate and reported: the component's transaction commits before the kernel appends
//! its journal row, so a crash in between leaves a memory that has not replicated yet (it does
//! replicate when it is written again). The native path journals inside the same transaction. Fixing
//! it properly means either a `wa:kernel/sql` that can stamp the origin itself, or the seam returning
//! a unit of work the kernel commits — both belong to the WASI 0.3 pass (REPORT.md).
use crate::components::{compiled, component_dir, load_in, Installed};
use crate::sql_host::{self, Scalar, SqlFailure, SqlScope};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::Instant;
use wasmtime::component::{Linker, ResourceTable};
use wasmtime::{Store, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

/// The installed name this seam is served from (`<components>/memory.wasm`, `memory.json`).
pub const COMPONENT: &str = "memory";
/// How long one seam call may take end to end. A memory call is a handful of indexed statements; a
/// component that has not answered by then is wedged, and the caller's native fallback is better than
/// a node that is stuck on memory.
const DEFAULT_TIMEOUT_MS: u64 = 2_000;
/// The component's own memory cap, from `limits.memory_mb` in its manifest when present.
const DEFAULT_MEMORY_MB: u64 = 128;

// No `trappable`: the `wa:kernel/sql` functions answer with their own `error` variant, so a refused
// statement reaches the component as a value it can report instead of a trap that reads like a crash.
/// Where one call gets what it needs: the components directory (or an explicit artifact), the
/// database, and the call's deadline.
///
/// It is a value rather than ambient environment so a test can point two calls at two stores at once;
/// [`Config::from_env`] is the only place these are read from the process, which is what a node does.
#[derive(Clone, Debug)]
pub struct Config {
    pub components_dir: PathBuf,
    pub db: PathBuf,
    /// `WA_MEMORY_COMPONENT_WASM`: an artifact from this checkout instead of the pinned install.
    pub wasm: Option<PathBuf>,
    /// `WA_MEMORY_COMPONENT_MANIFEST`: the manifest that goes with `wasm`.
    pub manifest: Option<PathBuf>,
    pub timeout_ms: u64,
}

impl Config {
    pub fn from_env() -> Config {
        let env_path = |key: &str| std::env::var(key).ok().filter(|value| !value.is_empty()).map(PathBuf::from);
        Config {
            components_dir: component_dir(),
            db: sql_host::database_path(),
            wasm: env_path("WA_MEMORY_COMPONENT_WASM"),
            manifest: env_path("WA_MEMORY_COMPONENT_MANIFEST"),
            timeout_ms: std::env::var("WA_MEMORY_COMPONENT_TIMEOUT_MS")
                .ok()
                .and_then(|value| value.parse::<u64>().ok())
                .filter(|value| *value > 0)
                .unwrap_or(DEFAULT_TIMEOUT_MS),
        }
    }

    /// The same grant, against another database (a test's scratch store).
    pub fn with_db(mut self, db: impl Into<PathBuf>) -> Config {
        self.db = db.into();
        self
    }

    pub fn with_components(mut self, dir: impl Into<PathBuf>) -> Config {
        self.components_dir = dir.into();
        self
    }
}

wasmtime::component::bindgen!({
    path: "../../wit/memory",
    world: "memory-component",
});

use wa::kernel::types::Error as KError;

/// The store's data: a WASI view (a `cdylib` still imports `wasi:cli`/`io` through `std`) and the one
/// SQL session of this call, opened lazily so a call that never touches SQL never opens a file.
struct State {
    wasi: WasiCtx,
    limits: StoreLimits,
    table: ResourceTable,
    scope: SqlScope,
    session: Option<sql_host::SqlSession>,
    /// The first statement the grant refused, kept so the caller can report *why* rather than a
    /// generic failure. The component turns it into a value error itself; this is the host's copy.
    refused: Option<String>,
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

impl wasmtime::component::HasData for State {
    type Data<'a> = &'a mut State;
}

fn kernel_error(failure: SqlFailure) -> KError {
    match failure {
        SqlFailure::Refused(why) => KError::Refused(why),
        SqlFailure::Failed(why) => KError::Failed(why),
    }
}

fn scalar(value: wa::kernel::sql::Value) -> Scalar {
    match value {
        wa::kernel::sql::Value::Null => Scalar::Null,
        wa::kernel::sql::Value::Integer(n) => Scalar::Integer(n),
        wa::kernel::sql::Value::Real(f) => Scalar::Real(f),
        wa::kernel::sql::Value::Text(text) => Scalar::Text(text),
        wa::kernel::sql::Value::Blob(bytes) => Scalar::Blob(bytes),
    }
}

fn value(scalar: Scalar) -> wa::kernel::sql::Value {
    match scalar {
        Scalar::Null => wa::kernel::sql::Value::Null,
        Scalar::Integer(n) => wa::kernel::sql::Value::Integer(n),
        Scalar::Real(f) => wa::kernel::sql::Value::Real(f),
        Scalar::Text(text) => wa::kernel::sql::Value::Text(text),
        Scalar::Blob(bytes) => wa::kernel::sql::Value::Blob(bytes),
    }
}

impl State {
    /// The session this call runs on, opened on first use. A refusal to open is reported as a
    /// failure of the store, never as an empty answer.
    fn session(&mut self) -> Result<&mut sql_host::SqlSession, KError> {
        if self.session.is_none() {
            match self.scope.session() {
                Ok(session) => self.session = Some(session),
                Err(failure) => {
                    self.refused = Some(failure.to_string());
                    return Err(kernel_error(failure));
                }
            }
        }
        Ok(self.session.as_mut().expect("session just opened"))
    }
}

impl wa::kernel::sql::Host for State {
    fn query(&mut self, statement: String, params: Vec<wa::kernel::sql::Value>) -> Result<wa::kernel::sql::Rows, KError> {
        let bound: Vec<Scalar> = params.into_iter().map(scalar).collect();
        let answer = match self.session()?.query(&statement, &bound) {
            Ok(answer) => answer,
            Err(failure) => {
                self.refused = Some(failure.to_string());
                return Err(kernel_error(failure));
            }
        };
        Ok(wa::kernel::sql::Rows {
            columns: answer.columns,
            rows: answer.rows.into_iter().map(|row| row.into_iter().map(value).collect()).collect(),
            changes: answer.changes,
        })
    }

    fn exec(&mut self, statement: String, params: Vec<wa::kernel::sql::Value>) -> Result<wa::kernel::sql::Rows, KError> {
        let bound: Vec<Scalar> = params.into_iter().map(scalar).collect();
        let answer = match self.session()?.exec(&statement, &bound) {
            Ok(answer) => answer,
            Err(failure) => {
                self.refused = Some(failure.to_string());
                return Err(kernel_error(failure));
            }
        };
        Ok(wa::kernel::sql::Rows {
            columns: answer.columns,
            rows: answer.rows.into_iter().map(|row| row.into_iter().map(value).collect()).collect(),
            changes: answer.changes,
        })
    }
}

/// What a request carries: an operation and its arguments, never a scope, a statement or a path.
///
/// ```json
/// {"op":"recall","text":"deploy","limit":10,"scope":null,"exclusive":false,"origin":"node-a"}
/// ```
///
/// `origin` is only read for the journal row a mutating op produces.
///
/// The answer is `{"ok":true,"op":…,"result":…}` or `{"ok":false,"op":…,"error":…}`. `ok:false` is
/// what the router falls back on, and it always names a reason (`component_not_installed`,
/// `component_wedged`, `sql_policy_refused:…`, `invalid_memory_request`), never silence.
pub fn call(request: &Value) -> Value {
    call_with(&Config::from_env(), request)
}

/// [`call`] against an explicit configuration (the form a test uses, so no process-wide variable is
/// involved).
pub fn call_with(config: &Config, request: &Value) -> Value {
    let op = request.get("op").and_then(Value::as_str).unwrap_or_default().to_string();
    match dispatch(config, &op, request) {
        Ok(mut answer) => {
            answer["ok"] = json!(true);
            answer["op"] = json!(op);
            answer
        }
        Err(error) => json!({"ok": false, "op": op, "error": error}),
    }
}

/// The component this call runs: the pinned install, or — for a checkout that built it itself — the
/// artifact `WA_MEMORY_COMPONENT_WASM` names.
///
/// That override is the same one `WA_AGENT_CORE_WASM` gives the agent core, and like it, it bypasses
/// the components directory *and its pin*: it is a development path, used by
/// `scripts/test-memory-component.lua` and by a lane that has not deployed. A node serves the pinned
/// install; nothing here weakens that, because the variable is not set on a node that did not opt in.
fn component(config: &Config) -> Result<Installed, String> {
    let Some(path) = config.wasm.clone() else {
        return load_in(&config.components_dir, COMPONENT).map_err(|error| error.to_string());
    };
    let bytes = std::fs::read(&path).map_err(|error| format!("component_not_installed:{}:{error}", path.display()))?;
    let manifest_path = config.manifest.clone().unwrap_or_else(|| {
            let beside = std::path::Path::new(&path).with_file_name(format!("{COMPONENT}.json"));
            if beside.is_file() {
                beside
            } else {
                std::path::PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../components/memory/manifest.json"))
            }
        });
    let manifest: Value = std::fs::read_to_string(&manifest_path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .ok_or_else(|| format!("component_manifest_unreadable:{}", manifest_path.display()))?;
    Ok(Installed { name: COMPONENT.to_string(), sha256: hex_of(&bytes), bytes, manifest })
}

fn hex_of(bytes: &[u8]) -> String {
    use ring::digest::{digest, SHA256};
    digest(&SHA256, bytes).as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

fn dispatch(config: &Config, op: &str, request: &Value) -> Result<Value, String> {
    let installed = component(config).map_err(|error| format!("component_unavailable:{error}"))?;
    let scope = SqlScope::from_manifest(COMPONENT, config.db.clone(), &installed.manifest)
        .map_err(|error| format!("component_grant_invalid:{error}"))?
        .with_audit_file(config.components_dir.join(format!("{COMPONENT}.sql-audit.log")));
    let started = Instant::now();
    let (result, journal) = run_once(&installed, scope, op, request, config.timeout_ms)?;
    let mut answer = json!({"result": result});
    if let Some((entity, entry_op, payload)) = journal {
        let journalled = append_journal(config, &payload, entity, entry_op, request);
        answer["journalled"] = json!(journalled.is_ok());
        if let Err(error) = journalled {
            // Visible, not silent: the memory is stored, the replication entry is not.
            answer["journal_error"] = json!(error);
        }
    }
    answer["elapsed_ms"] = json!(started.elapsed().as_millis() as u64);
    Ok(answer)
}

/// One instance, one call. The store is dropped at the end, which also closes the SQL session and
/// rolls back a transaction the component left open.
fn run_once(
    installed: &Installed,
    scope: SqlScope,
    op: &str,
    request: &Value,
    timeout_ms: u64,
) -> Result<(Value, Option<Journal>), String> {
    let engine = crate::components::engine().map_err(|error| format!("component_engine:{error}"))?;
    let component = compiled(&engine, &installed.sha256, &installed.bytes)
        .map_err(|error| format!("component_compile:{error}"))?;
    let memory_mb = installed
        .manifest
        .get("limits")
        .and_then(|limits| limits.get("memory_mb"))
        .and_then(Value::as_u64)
        .filter(|mb| *mb > 0)
        .unwrap_or(DEFAULT_MEMORY_MB);
    let limits = StoreLimitsBuilder::new().memory_size((memory_mb as usize) << 20).build();
    let state = State {
        wasi: {
            let mut builder = WasiCtxBuilder::new();
            builder.args(&[COMPONENT]);
            builder.build()
        },
        limits,
        table: ResourceTable::new(),
        scope,
        session: None,
        refused: None,
    };
    let mut store = Store::new(&engine, state);
    store.limiter(|state| &mut state.limits);
    // A wedged guest is stopped by its epoch, not by waiting for it. The ticker lives in
    // `components::engine`; one tick is 10 ms, so the deadline is in whole ticks plus a margin.
    store.set_epoch_deadline(timeout_ms.div_ceil(10) + 1);
    let mut linker: Linker<State> = Linker::new(&engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker).map_err(|error| format!("component_link_wasi:{error}"))?;
    wa::kernel::sql::add_to_linker::<State, State>(&mut linker, |state: &mut State| state)
        .map_err(|error| format!("component_link_sql:{error}"))?;
    let bindings = MemoryComponent::instantiate(&mut store, &component, &linker).map_err(|error| {
        // A component that imports an interface this host does not serve fails here, visibly: a
        // link error is a deployment mistake, not an empty memory store.
        format!("component_instantiate:{error}")
    })?;
    let outcome = invoke(&mut store, &bindings, op, request);
    let refused = store.data().refused.clone();
    outcome.map_err(|error| match refused {
        Some(reason) => format!("sql_policy_refused:{reason}"),
        None => error,
    })
}

type Journal = (String, String, Value);

fn invoke(store: &mut Store<State>, bindings: &MemoryComponent, op: &str, request: &Value) -> Result<(Value, Option<Journal>), String> {
    let memory = bindings.wa_memory_memory();
    let text = |field: &str| -> String { request.get(field).and_then(Value::as_str).unwrap_or_default().to_string() };
    let optional = |field: &str| request.get(field).and_then(Value::as_str).map(str::to_string).filter(|v| !v.is_empty());
    let number = |field: &str, default: u32| -> u32 {
        request
            .get(field)
            .and_then(|value| value.as_u64().or_else(|| value.as_i64().and_then(|n| u64::try_from(n).ok())))
            .map(|value| value.min(u64::from(u32::MAX)) as u32)
            .unwrap_or(default)
    };
    let tags = |field: &str| -> Vec<String> {
        request
            .get(field)
            .and_then(Value::as_array)
            .map(|items| items.iter().filter_map(|item| item.as_str().map(str::to_string)).collect())
            .unwrap_or_default()
    };
    match op {
        "remember" => {
            let remembered = memory
                .call_remember(store, &text("content"), optional("scope").as_deref(), &tags("tags"), optional("id").as_deref())
                .map_err(|trap| trap_error("remember", &trap))?
                .map_err(|error| seam_error("remember", error))?;
            let payload = json!({
                "id": remembered.id,
                "scope": remembered.scope,
                "content": remembered.content,
                "tags": remembered.tags,
                "source": remembered.source,
                "created_at": remembered.created_at,
                "updated_at": remembered.updated_at,
                "content_sha256": remembered.content_sha256,
            });
            let journal = remembered.written.then(|| (remembered.id.clone(), "upsert".to_string(), payload));
            Ok((json!({"id": remembered.id, "written": remembered.written}), journal))
        }
        "recall" => {
            let rows = memory
                .call_recall(store, &text("text"), number("limit", 10), optional("scope").as_deref(), request.get("exclusive").and_then(Value::as_bool).unwrap_or(false))
                .map_err(|trap| trap_error("recall", &trap))?
                .map_err(|error| seam_error("recall", error))?;
            Ok((json!(rows.iter().map(memory_json).collect::<Vec<_>>()), None))
        }
        "forget" => {
            let forgotten = memory.call_forget(store, &text("id")).map_err(|trap| trap_error("forget", &trap))?
                .map_err(|error| seam_error("forget", error))?;
            let payload = json!({"id": text("id"), "deleted_at": forgotten.deleted_at, "updated_at": forgotten.deleted_at});
            let journal = forgotten.retired.then(|| (text("id"), "delete".to_string(), payload));
            Ok((json!({"retired": forgotten.retired, "deleted_at": forgotten.deleted_at}), journal))
        }
        "list" => {
            let rows = memory
                .call_list(store, optional("scope").as_deref(), number("limit", 50))
                .map_err(|trap| trap_error("list", &trap))?
                .map_err(|error| seam_error("list", error))?;
            Ok((json!(rows.iter().map(memory_json).collect::<Vec<_>>()), None))
        }
        "search_messages" => {
            let rows = memory
                .call_search_messages(store, &text("text"), optional("user_id").as_deref(), number("limit", 20))
                .map_err(|trap| trap_error("search_messages", &trap))?
                .map_err(|error| seam_error("search_messages", error))?;
            let out: Vec<Value> = rows
                .iter()
                .map(|hit| {
                    json!({
                        "id": hit.id,
                        "session_id": hit.session_id,
                        "seq": hit.seq,
                        "role": hit.role,
                        "content": hit.content,
                        "tool_name": hit.tool_name,
                        "ok": if hit.ok { 1 } else { 0 },
                        "created_at": hit.created_at,
                        "user_id": hit.user_id,
                        "title": hit.title,
                        "rank": hit.rank,
                    })
                })
                .collect();
            Ok((json!(out), None))
        }
        "sessions" => {
            let rows = memory
                .call_sessions(store, optional("user_id").as_deref(), number("limit", 30), request.get("states").and_then(Value::as_bool).unwrap_or(false))
                .map_err(|trap| trap_error("sessions", &trap))?
                .map_err(|error| seam_error("sessions", error))?;
            let out: Vec<Value> = rows
                .iter()
                .map(|session| {
                    json!({
                        "id": session.id,
                        "user_id": session.user_id,
                        "node_id": session.node_id,
                        "route_id": session.route_id,
                        "objective": session.objective,
                        "title": session.title,
                        "parent_session_id": session.parent_session_id,
                        "started_at": session.started_at,
                        "ended_at": session.ended_at,
                        "updated_at": session.updated_at,
                        "message_count": session.message_count,
                        "state": session.state,
                        "last_role": session.last_role,
                        "last_ok": session.last_ok,
                        "last_phase": session.last_phase,
                        "last_tool_calls": session.last_tool_calls,
                        "last_at": session.last_at,
                        "last_trace": session.last_trace,
                    })
                })
                .collect();
            Ok((json!(out), None))
        }
        "retention" => {
            let older = request.get("older_than_seconds").and_then(Value::as_f64).unwrap_or(0.0);
            let plan = memory.call_retention(store, older).map_err(|trap| trap_error("retention", &trap))?
                .map_err(|error| seam_error("retention", error))?;
            Ok((json!({"refused": plan.refused, "eligible": plan.eligible}), None))
        }
        other => Err(format!("invalid_memory_request:unknown_op:{other}")),
    }
}

fn memory_json(memory: &wa::memory::types::Memory) -> Value {
    json!({
        "id": memory.id,
        "scope": memory.scope,
        "content": memory.content,
        "tags": memory.tags,
        "source": memory.source,
        "created_at": memory.created_at,
        "updated_at": memory.updated_at,
        "rank": memory.rank,
    })
}

/// The call itself failed (a trap, the epoch deadline, a missing export). Reported apart from the
/// seam's own error value, so "the component stopped answering" never reads as "the store said no".
fn trap_error(op: &str, error: &wasmtime::Error) -> String {
    // The Display of a trap is the wasm backtrace; the reason ("wasm trap: interrupt") is in the
    // chain the Debug formatting carries, so the classification reads both and the report keeps one
    // line.
    let detail = error.to_string().lines().next().unwrap_or_default().to_string();
    let chain = format!("{error:?}").to_ascii_lowercase();
    let wedged = chain.contains("interrupt") || chain.contains("epoch deadline") || chain.contains("deadline reached");
    let kind = if wedged { "component_wedged" } else { "component_failed" };
    format!("{kind}:{op}:{detail}")
}

/// A seam error, named the way the caller has to read it: `invalid`/`not-found` are the store's own
/// answers (the caller handles them), `refused`/`failed` are the component's.
fn seam_error(op: &str, error: wa::memory::types::Error) -> String {
    match error {
        wa::memory::types::Error::Invalid(why) => format!("invalid_memory_request:{why}"),
        wa::memory::types::Error::NotFound => format!("memory_not_found:{op}"),
        wa::memory::types::Error::Refused(why) => format!("sql_policy_refused:{why}"),
        wa::memory::types::Error::Failed(why) => {
            if why.contains("interrupt") || why.contains("epoch") || why.contains("timeout") {
                format!("component_wedged:{op}:{why}")
            } else {
                format!("component_failed:{op}:{why}")
            }
        }
    }
}

/// Append the replication entry a mutation owes (`lua/core/memory.lua` `M.journal`, same columns).
///
/// The origin comes from the request because identity is the caller's: a component never names
/// itself, and the kernel's own view of "who am I" is resolved above this crate.
fn append_journal(config: &Config, payload: &Value, entity_id: String, op: String, request: &Value) -> Result<(), String> {
    let origin = request.get("origin").and_then(Value::as_str).unwrap_or_default().to_string();
    if origin.is_empty() {
        return Err("journal_origin_missing".into());
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    let connection = rusqlite::Connection::open(&config.db).map_err(|error| error.to_string())?;
    connection
        .execute(
            "INSERT INTO journal(kind,entity_id,op,origin,payload,created_at) VALUES(?,?,?,?,?,?)",
            rusqlite::params!["memory", entity_id, op, origin, payload.to_string(), now],
        )
        .map_err(|error| error.to_string())?;
    Ok(())
}

/// `host.memory(request_json)` -> the answer from [`call`]. One capability, one call: the Lua side
/// passes the operation and its arguments, never a scope or a statement.
pub extern "C-unwind" fn capability(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => call(&request),
        Err(_) => json!({"ok": false, "error": "invalid_memory_request:not_json"}),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

/// Whether the memory component is installed and loadable — what the router asks before routing, so a
/// missing component is a decision it makes with a reason instead of a failed call per operation.
pub fn available() -> Result<String, String> {
    let config = Config::from_env();
    let installed = component(&config).map_err(|error| format!("component_unavailable:{error}"))?;
    SqlScope::from_manifest(COMPONENT, config.db, &installed.manifest)
        .map_err(|error| format!("component_grant_invalid:{error}"))?;
    Ok(installed.sha256)
}

#[cfg(test)]
mod tests;
