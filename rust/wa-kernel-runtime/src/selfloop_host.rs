//! The self-loop seam, served: `wa:selfloop` in a component, the three `self_*` tables in the kernel.
//!
//! This is the other half of `sql_host`, one step after `memory_host`: it loads the installed
//! `selfloop` component, hands it one `wa:kernel/sql` session scoped by its manifest to
//! `self_wakes`, `self_notes`, `self_notes_archive` (read/write) and `sessions` (read), calls one
//! seam function, and turns the typed answer into the JSON the Lua core consumes.
//! `lua/core/selfloop.lua` routes here when `WA_SELFLOOP_COMPONENT=1`; the native path stays the
//! default and is byte-for-byte the code it always ran.
//!
//! Three rules this module is the place for, the same three `memory_host` states for `wa:memory`:
//!
//! 1. **The grant is the manifest's.** `SqlScope::from_manifest` reads the component's declared
//!    tables; a component that declares none can read nothing, and the caller cannot widen it: the
//!    request carries operations, never a scope or a statement.
//! 2. **A wedged or broken component never takes the node with it.** Every call has its own deadline
//!    (so does every statement, inside `sql_host`), and a failure answers `ok: false` with a reason
//!    the router logs before falling back to the native path.
//! 3. **A refusal is an answer, not a failure.** The seam's refusals (`wake_reason_required`, …) come
//!    back as `refused`, which the router returns to the model unchanged; only `ok: false` means the
//!    component could not answer. A refused wake must never read as a broken component, and a broken
//!    component must never read as a refused wake.
//!
//! What stays out of the component on purpose: running a probe (the QuickJS sandbox and the read-only
//! tool catalogue), the run scheduler a due wake is handed to, the hooks and the agent turn. This
//! module serves the three points the node participates in — [`plan`](crate), claim and settle — as
//! plain calls, so the tick keeps its shape.
use crate::components::{compiled, component_dir, load_in, Installed};
use crate::sql_host::{self, Scalar, SqlFailure, SqlScope};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::Instant;
use wasmtime::component::{Linker, ResourceTable};
use wasmtime::{Store, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

/// The installed name this seam is served from (`<components>/selfloop.wasm`, `selfloop.json`).
pub const COMPONENT: &str = "selfloop";
/// How long one seam call may take end to end. A self-loop call is a handful of indexed statements;
/// a component that has not answered by then is wedged, and the caller's native fallback is better
/// than a node stuck on its own scheduler.
const DEFAULT_TIMEOUT_MS: u64 = 2_000;
/// The component's own memory cap, from `limits.memory_mb` in its manifest when present.
const DEFAULT_MEMORY_MB: u64 = 64;

/// Where one call gets what it needs: the components directory (or an explicit artifact), the
/// database, and the call's deadline. A value rather than ambient environment, so a test can point
/// two calls at two stores at once; [`Config::from_env`] is the only place these are read from the
/// process, which is what a node does.
#[derive(Clone, Debug)]
pub struct Config {
    pub components_dir: PathBuf,
    pub db: PathBuf,
    /// `WA_SELFLOOP_COMPONENT_WASM`: an artifact from this checkout instead of the pinned install.
    pub wasm: Option<PathBuf>,
    /// `WA_SELFLOOP_COMPONENT_MANIFEST`: the manifest that goes with `wasm`.
    pub manifest: Option<PathBuf>,
    pub timeout_ms: u64,
}

impl Config {
    pub fn from_env() -> Config {
        let env_path = |key: &str| std::env::var(key).ok().filter(|value| !value.is_empty()).map(PathBuf::from);
        Config {
            components_dir: component_dir(),
            db: sql_host::database_path(),
            wasm: env_path("WA_SELFLOOP_COMPONENT_WASM"),
            manifest: env_path("WA_SELFLOOP_COMPONENT_MANIFEST"),
            timeout_ms: std::env::var("WA_SELFLOOP_COMPONENT_TIMEOUT_MS")
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
    path: "../../wit/selfloop",
    world: "selfloop-component",
});

use wa::kernel::types::Error as KError;
use wa::selfloop::types::Error as SeamError;

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
    /// How many statements this call issued. Reported in the answer because it is the one number that
    /// says what a seam call *costs* the kernel (`scripts/bench-selfloop.sh` compares it with the
    /// native path's statement count), and because a component that opens the store per row would be
    /// visible there instead of looking like latency.
    statements: u64,
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
        self.statements += 1;
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
        self.statements += 1;
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

    /// memtx's unit of work, offered to every `wa:kernel/sql` guest. The self-loop opens no unit
    /// today; the methods exist so the vendored interface stays equal to the kernel's, and they
    /// delegate to the same session (with the same refusal bookkeeping) as `query`/`exec`.
    fn begin_unit(&mut self) -> Result<(), KError> {
        match self.session()?.begin_unit() {
            Ok(()) => Ok(()),
            Err(failure) => {
                self.refused = Some(failure.to_string());
                Err(kernel_error(failure))
            }
        }
    }

    fn commit_unit(&mut self, entry: Option<wa::kernel::sql::JournalEntry>) -> Result<(), KError> {
        let entry = entry.map(|entry| crate::sql_host::JournalEntry {
            entity_id: entry.entity_id,
            op: entry.op,
            payload: entry.payload,
        });
        match self.session()?.commit_unit(entry) {
            Ok(()) => Ok(()),
            Err(failure) => {
                self.refused = Some(failure.to_string());
                Err(kernel_error(failure))
            }
        }
    }

    fn rollback_unit(&mut self) -> Result<(), KError> {
        match self.session()?.rollback_unit() {
            Ok(()) => Ok(()),
            Err(failure) => {
                self.refused = Some(failure.to_string());
                Err(kernel_error(failure))
            }
        }
    }
}

// --------------------------------------------------------------------------------- the answer shape

/// What a request carries: an operation and its arguments, never a scope, a statement or a path.
///
/// ```json
/// {"op":"schedule","owner":"master","session_id":"s1","in_seconds":60,"reason":"check","now":1700000000}
/// ```
///
/// The answer is one of three:
///
/// * `{"ok":true,"op":…,"result":…}` — the seam's answer, in the shape the native function returns;
/// * `{"ok":true,"op":…,"refused":…}` — the seam refused (`wake_reason_required`, …). The table is
///   the native refusal, field for field, so the caller returns it to the model unchanged;
/// * `{"ok":false,"op":…,"error":…}` — the component could not answer (`component_not_installed`,
///   `component_wedged`, `sql_policy_refused:…`). The router logs one line and runs the native path.
pub fn call(request: &Value) -> Value {
    call_with(&Config::from_env(), request)
}

/// [`call`] against an explicit configuration (the form a test uses, so no process-wide variable is
/// involved).
pub fn call_with(config: &Config, request: &Value) -> Value {
    let op = request.get("op").and_then(Value::as_str).unwrap_or_default().to_string();
    match dispatch(config, &op, request) {
        Ok(answer) => answer,
        Err(error) => json!({"ok": false, "op": op, "error": error}),
    }
}

/// The component this call runs: the pinned install, or — for a checkout that built it itself — the
/// artifact `WA_SELFLOOP_COMPONENT_WASM` names. That override bypasses the components directory *and
/// its pin*: it is the development path `scripts/test-selfloop-component.lua` uses, and the same one
/// `WA_MEMORY_COMPONENT_WASM` gives the memory seam.
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
            std::path::PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../components/selfloop/manifest.json"))
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
    let answer = run_once(&installed, scope, op, request, config.timeout_ms)?;
    let mut answer = answer;
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
) -> Result<Value, String> {
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
        statements: 0,
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
    let bindings = SelfloopComponent::instantiate(&mut store, &component, &linker).map_err(|error| {
        // A component that imports an interface this host does not serve fails here, visibly: a link
        // error is a deployment mistake, not "no wakes".
        format!("component_instantiate:{error}")
    })?;
    let outcome = invoke(&mut store, &bindings, op, request);
    let refused = store.data().refused.clone();
    let statements = store.data().statements;
    outcome
        .map(|mut answer| {
            answer["sql_statements"] = json!(statements);
            answer
        })
        .map_err(|error| match refused {
        Some(reason) => format!("sql_policy_refused:{reason}"),
        None => error,
        })
}

// ------------------------------------------------------------------------------------ the op table

fn text_field(request: &Value, field: &str) -> String {
    request.get(field).and_then(Value::as_str).unwrap_or_default().to_string()
}

fn optional(request: &Value, field: &str) -> Option<String> {
    request.get(field).and_then(Value::as_str).map(str::to_string).filter(|value| !value.is_empty())
}

fn number(request: &Value, field: &str) -> Option<f64> {
    request.get(field).and_then(Value::as_f64)
}

fn flag(request: &Value, field: &str) -> bool {
    request.get(field).and_then(Value::as_bool).unwrap_or(false)
}

fn topics(request: &Value, field: &str) -> Option<Vec<String>> {
    request.get(field).and_then(Value::as_array).map(|items| {
        items.iter().filter_map(|item| item.as_str().map(str::to_string)).collect()
    })
}

fn wake_json(wake: &wa::selfloop::types::Wake) -> Value {
    let mut out = json!({
        "id": wake.id,
        "status": wake.status,
        "reason": wake.reason,
        "prompt": wake.prompt,
        "prompt_bytes": wake.prompt_bytes,
        "due_at": wake.due_at,
        "every_seconds": wake.every_seconds,
        "on": wake.on,
        "probe": wake.probe,
        "has_event": wake.has_event,
        "fired_at": wake.fired_at,
        "created_at": wake.created_at,
        "updated_at": wake.updated_at,
        "attempts": wake.attempts,
        "last_error": wake.last_error,
    });
    // The native `view` adds `in_seconds` only when there is a clock to count down.
    if wake.due_at.is_some() {
        if let Some(in_seconds) = wake.in_seconds {
            out["in_seconds"] = json!(in_seconds);
        }
    }
    if out["due_at"].is_null() {
        out.as_object_mut().map(|object| object.remove("due_at"));
    }
    if out["every_seconds"].is_null() {
        out.as_object_mut().map(|object| object.remove("every_seconds"));
    }
    out
}

fn summary_json(summary: &wa::selfloop::types::WakeSummary) -> Value {
    let mut out = json!({
        "pending": summary.pending,
        "event_pending": summary.event_pending,
        "dispatching": summary.dispatching,
        "total": summary.total,
        "now": summary.now,
    });
    if let Some(next_at) = summary.next_at {
        out["next_at"] = json!(next_at);
        if let Some(in_seconds) = summary.next_in_seconds {
            out["next_in_seconds"] = json!(in_seconds);
        }
    }
    out
}

/// A seam refusal, as the native function answers it: the same `error` name, the same extra fields,
/// and the same `effect` class (`unknown` only for a run that was already handed over).
fn refusal_json(error: &SeamError) -> Value {
    let none = |name: &str| json!({"error": name, "effect": "none"});
    match error {
        SeamError::RequiresSession => none("selfloop_requires_session"),
        SeamError::UnknownSession => none("selfloop_unknown_session"),
        SeamError::ForbiddenSession => none("selfloop_forbidden_session"),
        SeamError::NotForSubagent => none("wake_not_for_subagent"),
        SeamError::ReasonRequired => none("wake_reason_required"),
        SeamError::ReasonTooLong => none("wake_reason_too_long"),
        SeamError::PromptTooLong => none("wake_prompt_too_long"),
        SeamError::ProbeTooLong => none("wake_probe_too_long"),
        SeamError::TimeAndEventExclusive => none("wake_time_and_event_are_exclusive"),
        SeamError::NeedsWakeTarget => none("wake_needs_in_seconds_at_or_on"),
        SeamError::InSecondsAndAtExclusive => none("wake_in_seconds_and_at_are_exclusive"),
        SeamError::InSecondsNotANumber => none("wake_in_seconds_must_be_a_non_negative_number"),
        SeamError::AtNotANumber => none("wake_at_must_be_unix_epoch_seconds"),
        SeamError::AtInThePast(past) => {
            json!({"error": "wake_at_is_in_the_past", "effect": "none", "now": past.now, "at": past.at})
        }
        SeamError::EverySecondsTooSmall(minimum) => {
            json!({"error": "wake_every_seconds_too_small", "minimum": minimum, "effect": "none"})
        }
        SeamError::EventTakesNoTimeArguments => none("wake_event_takes_no_time_arguments"),
        SeamError::OnRequiresTopics => none("wake_on_requires_topics"),
        SeamError::OnTooMany => none("wake_on_too_many"),
        SeamError::OnEntryMustBeAString => none("wake_on_entry_must_be_a_string"),
        SeamError::OnEntryTooLongOrEmpty => none("wake_on_entry_too_long_or_empty"),
        // The native refusal names the duplicate entry, and the parity suite compares the name.
        SeamError::OnDuplicate(topic) => none(&format!("wake_on_duplicate:{topic}")),
        SeamError::ProbeNeedsCadence => json!({
            "error": "wake_probe_needs_every_seconds",
            "effect": "none",
            "note": "A probe with no recheck cadence could only run once. Give every_seconds for a time wake, or use an event wake.",
        }),
        SeamError::WakeIdRequired => none("wake_id_required"),
        SeamError::PublishTopicRequired => none("publish_topic_required"),
        SeamError::UnknownWake => none("unknown_wake"),
        SeamError::WakeAlreadyDispatching(wake) => json!({
            "error": "wake_already_dispatching",
            "effect": "unknown",
            "wake": wake_json(wake),
            "note": "The run has been handed to the scheduler; cancelling it here would claim an effect this call cannot observe.",
        }),
        SeamError::WakeNotPending(status) => json!({"error": "wake_not_pending", "status": status, "effect": "none"}),
        SeamError::NotDispatching(status) => {
            json!({"error": "self_wake_not_dispatching", "status": status, "effect": "none"})
        }
        SeamError::NotesTextRequired => none("notes_text_required"),
        SeamError::NotesTooLarge(facts) => {
            let mut out = json!({"error": "notes_too_large", "limit": facts.limit, "effect": "none"});
            if let Some(current) = facts.current_bytes {
                out["current_bytes"] = json!(current);
                out["note"] = json!(
                    "Compact the notes (notes_compact) or write a shorter version; nothing was appended."
                );
            }
            out
        }
        SeamError::KeepLinesInvalid => none("notes_keep_lines_must_be_a_whole_number_between_1_and_1000"),
        SeamError::UnknownNotesVersion => none("unknown_notes_version"),
        SeamError::StoreFailed(why) => json!({"error": format!("selfloop_store_failed:{why}")}),
    }
}

/// What a seam error means for this module: a refusal is an answer (`refused`), a store fault is the
/// component failing to answer what it was asked (`Err`, which the router falls back on).
fn refused_or_failed(op: &str, error: SeamError) -> Result<Value, String> {
    match &error {
        SeamError::StoreFailed(why) => Err(format!("component_failed:{op}:{why}")),
        _ => Ok(json!({"ok": true, "op": op, "refused": refusal_json(&error)})),
    }
}

fn invoke(store: &mut Store<State>, bindings: &SelfloopComponent, op: &str, request: &Value) -> Result<Value, String> {
    let seam = bindings.wa_selfloop_selfloop();
    let now = number(request, "now").unwrap_or(0.0);
    match op {
        "schedule" => {
            let schedule = wa::selfloop::types::ScheduleRequest {
                owner: text_field(request, "owner"),
                session_id: text_field(request, "session_id"),
                reason: text_field(request, "reason"),
                prompt: text_field(request, "prompt"),
                in_seconds: number(request, "in_seconds"),
                at: number(request, "at"),
                every_seconds: number(request, "every_seconds"),
                on: topics(request, "on"),
                probe: text_field(request, "probe"),
                now,
            };
            match seam.call_schedule(store, &schedule).map_err(|trap| trap_error("schedule", &trap))? {
                Ok(wake) => Ok(json!({"ok": true, "op": op, "result": {"ok": true, "wake": wake_json(&wake)}})),
                Err(error) => refused_or_failed(op, error),
            }
        }
        "list" => {
            let who = caller(request);
            match seam
                .call_list(store, &who, flag(request, "all"), now)
                .map_err(|trap| trap_error("list", &trap))?
            {
                Ok(page) => {
                    // The native `M.list` answers these six fields and no more: a caller diffing the
                    // two paths must not have to know which one it talked to.
                    let mut out = json!({
                        "wakes": page.wakes.iter().map(wake_json).collect::<Vec<_>>(),
                        "count": page.count,
                        "now": page.summary.now,
                        "pending": page.summary.pending,
                        "event_pending": page.summary.event_pending,
                    });
                    if let Some(next_at) = page.summary.next_at {
                        out["next_at"] = json!(next_at);
                    }
                    Ok(json!({"ok": true, "op": op, "result": out}))
                }
                Err(error) => refused_or_failed(op, error),
            }
        }
        "cancel" => {
            let who = caller(request);
            match seam
                .call_cancel(store, &who, &text_field(request, "id"), now)
                .map_err(|trap| trap_error("cancel", &trap))?
            {
                Ok(id) => Ok(json!({"ok": true, "op": op, "result": {"ok": true, "cancelled": id}})),
                Err(error) => refused_or_failed(op, error),
            }
        }
        "summary" => match seam
            .call_summary(store, &text_field(request, "session_id"), now)
            .map_err(|trap| trap_error("summary", &trap))?
        {
            Ok(summary) => Ok(json!({"ok": true, "op": op, "result": summary_json(&summary)})),
            Err(error) => refused_or_failed(op, error),
        },
        "notes_read" => {
            let who = caller(request);
            match seam
                .call_notes_read(store, &who, optional(request, "version").as_deref(), flag(request, "versions"), now)
                .map_err(|trap| trap_error("notes_read", &trap))?
            {
                Ok(answer) => Ok(json!({"ok": true, "op": op, "result": notes_answer(&answer)})),
                Err(error) => refused_or_failed(op, error),
            }
        }
        "notes_write" => {
            let who = caller(request);
            match seam
                .call_notes_write(store, &who, &text_field(request, "text"), now)
                .map_err(|trap| trap_error("notes_write", &trap))?
            {
                Ok(report) => Ok(json!({"ok": true, "op": op, "result": notes_write_json(&report)})),
                Err(error) => refused_or_failed(op, error),
            }
        }
        "notes_append" => {
            let who = caller(request);
            match seam
                .call_notes_append(store, &who, &text_field(request, "text"), now)
                .map_err(|trap| trap_error("notes_append", &trap))?
            {
                Ok(report) => Ok(json!({"ok": true, "op": op, "result": notes_write_json(&report)})),
                Err(error) => refused_or_failed(op, error),
            }
        }
        "notes_compact" => {
            let who = caller(request);
            let keep = request.get("keep_lines").and_then(Value::as_u64).unwrap_or(40).min(u64::from(u32::MAX)) as u32;
            match seam
                .call_notes_compact(store, &who, keep, now)
                .map_err(|trap| trap_error("notes_compact", &trap))?
            {
                Ok(report) => Ok(json!({"ok": true, "op": op, "result": notes_compact_json(&report)})),
                Err(error) => refused_or_failed(op, error),
            }
        }
        "publish" => {
            let event = wa::selfloop::types::EventFact {
                topic: text_field(request, "topic"),
                id: optional(request, "id"),
                session: optional(request, "session"),
                now,
            };
            match seam.call_publish(store, &event).map_err(|trap| trap_error("publish", &trap))? {
                Ok(report) => Ok(json!({"ok": true, "op": op, "result": {
                    "ok": true,
                    "topic": report.topic,
                    "matched": report.matched.len(),
                    "wake_ids": report.matched,
                }})),
                Err(error) => refused_or_failed(op, error),
            }
        }
        "plan" => {
            let stale = number(request, "stale_seconds").unwrap_or(1800.0);
            match seam.call_plan(store, now, stale).map_err(|trap| trap_error("plan", &trap))? {
                Ok(plan) => Ok(json!({"ok": true, "op": op, "result": {
                    "reconciled": plan.reconciled,
                    "due": plan.due.iter().map(|row| json!({
                        "id": row.id,
                        "owner": row.owner,
                        "session_id": row.session_id,
                        "reason": row.reason,
                        "probe": row.probe,
                        "every_seconds": row.every_seconds,
                        "attempts": row.attempts,
                    })).collect::<Vec<_>>(),
                }})),
                Err(error) => refused_or_failed(op, error),
            }
        }
        "probe" => {
            let observed = request.get("result").map(|result| wa::selfloop::types::ProbeResult {
                changed: result.get("changed").and_then(Value::as_bool).unwrap_or(false),
                detail: result.get("detail").and_then(Value::as_str).unwrap_or_default().to_string(),
            });
            match seam
                .call_probe(store, &text_field(request, "id"), observed.as_ref(), optional(request, "failure").as_deref(), now)
                .map_err(|trap| trap_error("probe", &trap))?
            {
                Ok(decision) => Ok(json!({"ok": true, "op": op, "result": match decision {
                    exports::wa::selfloop::selfloop::ProbeDecision::Skipped => "skipped",
                    exports::wa::selfloop::selfloop::ProbeDecision::Wake => "wake",
                }})),
                Err(error) => refused_or_failed(op, error),
            }
        }
        "claim" => match seam
            .call_claim(store, &text_field(request, "id"), &text_field(request, "boot"), now)
            .map_err(|trap| trap_error("claim", &trap))?
        {
            // Wrapped, because a claim that lost its compare-and-set is a *successful* answer with
            // no row: an empty result and a broken component must not look the same to the caller.
            Ok(claimed) => Ok(json!({"ok": true, "op": op, "result": {"claimed": claimed.map(|wake| wake_json(&wake))}})),
            Err(error) => refused_or_failed(op, error),
        },
        "claim_due" => match seam
            .call_claim_due(
                store,
                &text_field(request, "session_id"),
                &text_field(request, "owner"),
                &text_field(request, "boot"),
                now,
            )
            .map_err(|trap| trap_error("claim_due", &trap))?
        {
            Ok(claimed) => Ok(json!({"ok": true, "op": op, "result": {"claimed": claimed.map(|wake| wake_json(&wake))}})),
            Err(error) => refused_or_failed(op, error),
        },
        "settle_dispatch" => {
            let outcome = match text_field(request, "outcome").as_str() {
                "accepted" => wa::selfloop::types::DispatchOutcome::Accepted,
                "not_started" => wa::selfloop::types::DispatchOutcome::NotStarted(text_field(request, "error")),
                "unknown" => wa::selfloop::types::DispatchOutcome::Unknown(text_field(request, "error")),
                other => return Err(format!("invalid_selfloop_request:unknown_outcome:{other}")),
            };
            let attempts = request.get("attempts").and_then(Value::as_u64).unwrap_or(1);
            match seam
                .call_settle_dispatch(store, &text_field(request, "id"), &outcome, attempts, now)
                .map_err(|trap| trap_error("settle_dispatch", &trap))?
            {
                Ok(status) => Ok(json!({"ok": true, "op": op, "result": status})),
                Err(error) => refused_or_failed(op, error),
            }
        }
        "finish" => match seam
            .call_finish(store, &text_field(request, "id"), flag(request, "ok"), &text_field(request, "detail"), now)
            .map_err(|trap| trap_error("finish", &trap))?
        {
            Ok(report) => Ok(json!({"ok": true, "op": op, "result": {
                "status": report.status,
                "due_at": report.due_at,
            }})),
            Err(error) => refused_or_failed(op, error),
        },
        "turn" => match seam
            .call_turn(store, &wa::selfloop::types::TurnRequest {
                id: text_field(request, "id"),
                session_id: text_field(request, "session_id"),
                reason: text_field(request, "reason"),
                prompt: text_field(request, "prompt"),
                event_rendering: text_field(request, "event_rendering"),
                probe_rendering: text_field(request, "probe_rendering"),
                now,
            })
            .map_err(|trap| trap_error("turn", &trap))?
        {
            Ok(wake_turn) => Ok(json!({"ok": true, "op": op, "result": {
                "content": wake_turn.content,
                "trace": {
                    "kind": wake_turn.trace.kind,
                    "version": wake_turn.trace.version,
                    "id": wake_turn.trace.id,
                    "reason": wake_turn.trace.reason,
                    "at": wake_turn.trace.at,
                    "probe": wake_turn.trace.probe,
                    "event": wake_turn.trace.event,
                },
            }})),
            Err(error) => refused_or_failed(op, error),
        },
        "cancel_claimed" => match seam
            .call_cancel_claimed(store, &text_field(request, "id"), now)
            .map_err(|trap| trap_error("cancel_claimed", &trap))?
        {
            Ok(cancelled) => Ok(json!({"ok": true, "op": op, "result": {"cancelled": cancelled}})),
            Err(error) => refused_or_failed(op, error),
        },
        other => Err(format!("invalid_selfloop_request:unknown_op:{other}")),
    }
}

fn caller(request: &Value) -> wa::selfloop::types::Caller {
    wa::selfloop::types::Caller {
        owner: text_field(request, "owner"),
        session_id: text_field(request, "session_id"),
    }
}

fn notes_answer(answer: &wa::selfloop::types::NotesReadAnswer) -> Value {
    use wa::selfloop::types::NotesReadAnswer;
    match answer {
        NotesReadAnswer::Document(notes) => json!({"ok": true, "text": notes.text, "bytes": notes.bytes,
            "lines": notes.lines, "updated_at": notes.updated_at, "empty": notes.empty}),
        NotesReadAnswer::Versions(versions) => json!({
            "ok": true,
            "versions": versions.iter().map(|version| json!({
                "version": version.version,
                "bytes": version.bytes,
                "reason": version.reason,
                "created_at": version.created_at,
            })).collect::<Vec<_>>(),
            "count": versions.len(),
        }),
        NotesReadAnswer::Archive(archive) => json!({"ok": true, "version": archive.version,
            "reason": archive.reason, "text": archive.text, "bytes": archive.bytes,
            "created_at": archive.created_at}),
    }
}

/// A compaction's answer, in the two shapes the native `notes_compact` returns: an unchanged
/// document reports neither an archive nor a note, and a compaction reports both.
fn notes_compact_json(report: &exports::wa::selfloop::selfloop::NotesCompactReport) -> Value {
    if report.unchanged {
        return json!({
            "ok": true,
            "unchanged": true,
            "kept_lines": report.kept_lines,
            "bytes": report.bytes,
        });
    }
    json!({
        "ok": true,
        "archived": report.archived,
        "kept_lines": report.kept_lines,
        "archived_lines": report.archived_lines,
        "before_bytes": report.before_bytes,
        "bytes": report.bytes,
        "note": "The previous document is kept; read it with notes_read {version}.",
    })
}

fn notes_write_json(report: &wa::selfloop::types::NotesWriteReport) -> Value {
    json!({"ok": true, "bytes": report.bytes, "archived": report.archived, "replaced": report.replaced})
}

/// The call itself failed (a trap, the epoch deadline, a missing export). Reported apart from the
/// seam's own error value, so "the component stopped answering" never reads as "the seam said no".
fn trap_error(op: &str, error: &wasmtime::Error) -> String {
    let detail = error.to_string().lines().next().unwrap_or_default().to_string();
    let chain = format!("{error:?}").to_ascii_lowercase();
    let wedged = chain.contains("interrupt") || chain.contains("epoch deadline") || chain.contains("deadline reached");
    let kind = if wedged { "component_wedged" } else { "component_failed" };
    format!("{kind}:{op}:{detail}")
}

/// `host.selfloop(request_json)` -> the answer from [`call`]. One capability, one call: the Lua side
/// passes the operation and its arguments, never a scope or a statement.
pub extern "C-unwind" fn capability(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => call(&request),
        Err(_) => json!({"ok": false, "error": "invalid_selfloop_request:not_json"}),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

/// Whether the self-loop component is installed and loadable — what the router asks before routing, so
/// a missing component is a decision it makes with a reason instead of a failed call per operation.
pub fn available() -> Result<String, String> {
    let config = Config::from_env();
    let installed = component(&config).map_err(|error| format!("component_unavailable:{error}"))?;
    SqlScope::from_manifest(COMPONENT, config.db, &installed.manifest)
        .map_err(|error| format!("component_grant_invalid:{error}"))?;
    Ok(installed.sha256)
}

#[cfg(test)]
mod tests;
