//! The hooks seam, served: `wa:hooks` in a component, the config and the verdicts in the core.
//!
//! This is the third of the core-split seams after `memory_host` and `selfloop_host`, and the first
//! one whose component holds **no capability at all**: the engine's rules move into the guest, and the
//! two things they cannot do stay here — reading the operator's config files (a component has no path
//! and no grant to `~/.wasm-agent`) and running a hook (a command hook is a process with the node's
//! grants; a Lua plugin hook is a function in the node's interpreter). The node hands the config text
//! over, runs the entries the component named, and asks again what each answer means.
//!
//! Two rules this module is the place for:
//!
//! 1. **A refusal is an answer, a failure is not.** Every call has its own deadline; a wedged or
//!    missing component answers `ok: false` with a reason the Lua router logs once per (op, reason)
//!    before running the native path. The native path is untouched code, so a broken seam degrades to
//!    exactly what ran before the seam existed.
//! 2. **The guest decides, the host acts.** No statement here interprets a hook's answer, clips a
//!    message, matches a matcher or orders an event's entries: that is the point of the seam
//!    (`docs/CORE-SPLIT.md`). This module converts typed records to and from the JSON the Lua core
//!    consumes, and nothing else.
//!
//! Bounds, and why they are here rather than in the guest: a wedged guest is stopped by the epoch
//! deadline, and the component's memory cap comes from its manifest, so a hook engine that loops or
//! piles up cannot take the node with it (the per-hook timeout is the *guest's* rule; the *cutting*
//! is the node's `host.exec` deadline, unchanged).
use crate::components::{compiled, component_dir, load_in, Installed};
use serde_json::{json, Map, Value};
use std::path::PathBuf;
use std::time::Instant;
use wasmtime::component::{Linker, ResourceTable};
use wasmtime::{Store, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

/// The installed name this seam is served from (`<components>/hooks.wasm`, `hooks.json`).
pub const COMPONENT: &str = "hooks";
/// How long one seam call may take end to end. A decide step is one row and a few string operations;
/// a component that has not answered in this window is wedged, and the native fallback is better than
/// a turn stuck in a hook engine.
const DEFAULT_TIMEOUT_MS: u64 = 2_000;
/// The component's own memory cap, from `limits.memory_mb` in its manifest when present.
const DEFAULT_MEMORY_MB: u64 = 32;

wasmtime::component::bindgen!({
    path: "../../wit/hooks",
    world: "hooks-component",
});

use wa::hooks::types as seam;

/// Where one call gets what it needs: the components directory (or an explicit artifact), the
/// call's deadline. A value rather than ambient environment, so a test can point two calls at two
/// artifacts at once; [`Config::from_env`] is the only place these are read from the process.
#[derive(Clone, Debug)]
pub struct Config {
    pub components_dir: PathBuf,
    /// `WA_HOOKS_COMPONENT_WASM`: an artifact from this checkout instead of the pinned install.
    pub wasm: Option<PathBuf>,
    /// `WA_HOOKS_COMPONENT_MANIFEST`: the manifest that goes with `wasm`.
    pub manifest: Option<PathBuf>,
    pub timeout_ms: u64,
}

impl Config {
    pub fn from_env() -> Config {
        let env_path = |key: &str| std::env::var(key).ok().filter(|value| !value.is_empty()).map(PathBuf::from);
        Config {
            components_dir: component_dir(),
            wasm: env_path("WA_HOOKS_COMPONENT_WASM"),
            manifest: env_path("WA_HOOKS_COMPONENT_MANIFEST"),
            timeout_ms: std::env::var("WA_HOOKS_COMPONENT_TIMEOUT_MS")
                .ok()
                .and_then(|value| value.parse::<u64>().ok())
                .filter(|value| *value > 0)
                .unwrap_or(DEFAULT_TIMEOUT_MS),
        }
    }

    pub fn with_components(mut self, dir: impl Into<PathBuf>) -> Config {
        self.components_dir = dir.into();
        self
    }
}

/// The store's data: a WASI view (a `cdylib` still imports `wasi:cli`/`io` through `std`) and the
/// store's limits. No SQL session, no file, no socket: this component has no capability.
struct State {
    wasi: WasiCtx,
    limits: StoreLimits,
    table: ResourceTable,
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

impl wasmtime::component::HasData for State {
    type Data<'a> = &'a mut State;
}

// --------------------------------------------------------------------------------- the answer shape

/// `host.hooks(request_json)` -> the answer. One capability, one call per seam operation: the Lua side
/// passes the operation and its arguments, never a capability, a path or a statement.
pub extern "C-unwind" fn capability(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => call(&request),
        Err(_) => json!({"ok": false, "error": "invalid_hooks_request:not_json"}),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

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
/// artifact `WA_HOOKS_COMPONENT_WASM` names. The override bypasses the components directory *and its
/// pin*: it is the development path `scripts/test-hooks-component.lua` uses, and the same one
/// `WA_SELFLOOP_COMPONENT_WASM` gives the self-loop seam.
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
            std::path::PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../components/hooks/manifest.json"))
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
    let started = Instant::now();
    let mut answer = run_once(&installed, op, request, config.timeout_ms)?;
    answer["elapsed_ms"] = json!(started.elapsed().as_millis() as u64);
    Ok(answer)
}

/// One instance, one call. The store is dropped at the end, which is what keeps a decision from
/// depending on another one having run in the same guest.
fn run_once(installed: &Installed, op: &str, request: &Value, timeout_ms: u64) -> Result<Value, String> {
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
    };
    let mut store = Store::new(&engine, state);
    store.limiter(|state| &mut state.limits);
    // A wedged guest is stopped by its epoch, not by waiting for it. The ticker lives in
    // `components::engine`; one tick is 10 ms, so the deadline is in whole ticks plus a margin.
    store.set_epoch_deadline(timeout_ms.div_ceil(10) + 1);
    let mut linker: Linker<State> = Linker::new(&engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker).map_err(|error| format!("component_link_wasi:{error}"))?;
    let bindings = HooksComponent::instantiate(&mut store, &component, &linker).map_err(|error| {
        // A component that imports an interface this host does not serve fails here, visibly: a link
        // error is a deployment mistake, not "no hooks configured".
        format!("component_instantiate:{error}")
    })?;
    invoke(&mut store, &bindings, op, request)
}

/// Whether the hooks component is installed and loadable — what a router may ask before routing, so a
/// missing component is a decision with a reason instead of a failed call per event.
pub fn available() -> Result<String, String> {
    let config = Config::from_env();
    let installed = component(&config).map_err(|error| format!("component_unavailable:{error}"))?;
    Ok(installed.sha256)
}

// ------------------------------------------------------------------------------ records <-> JSON

fn text_field(request: &Value, field: &str) -> String {
    request.get(field).and_then(Value::as_str).unwrap_or_default().to_string()
}

fn flag(request: &Value, field: &str) -> bool {
    request.get(field).and_then(Value::as_bool).unwrap_or(false)
}

fn bytes_field(request: &Value, field: &str) -> Vec<u8> {
    request.get(field).and_then(Value::as_str).unwrap_or_default().as_bytes().to_vec()
}

fn optional_bytes(request: &Value, field: &str) -> Option<Vec<u8>> {
    request.get(field).and_then(Value::as_str).map(|text| text.as_bytes().to_vec())
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}


fn entry_from(value: &Value) -> seam::Entry {
    let field = |name: &str| value.get(name).and_then(Value::as_str).unwrap_or_default();
    let kind = value.get("kind").and_then(Value::as_str).unwrap_or("command");
    seam::Entry {
        name: field("name").to_string(),
        event: field("event").to_string(),
        kind: kind.to_string(),
        matcher: value.get("matcher").and_then(Value::as_str).map(str::to_string),
        command: field("command").to_string(),
        timeout_ms: value.get("timeout_ms").and_then(Value::as_f64).unwrap_or(0.0),
        on_ask: field("on_ask").to_string(),
        origin: field("origin").to_string(),
        path: value.get("path").and_then(Value::as_str).map(str::to_string),
        order: value.get("order").and_then(Value::as_u64).unwrap_or(0) as u32,
    }
}

/// A timeout as the native config carries it: `5000` is an integer there and must not become `5000.0`
/// here, because `/hooks` prints it and a caller diffs the two paths.
fn integral(value: f64) -> Value {
    if value.fract() == 0.0 && value.abs() < 9.0e15 {
        json!(value as i64)
    } else {
        json!(value)
    }
}

fn entry_json(entry: &seam::Entry) -> Value {
    // No `kind`: a configured entry in the native view is a command hook, and `kind` is only ever set
    // on a Lua plugin hook - a caller comparing the two paths would see a field that is not there.
    let mut out = json!({
        "name": entry.name,
        "event": entry.event,
        "command": entry.command,
        "timeout_ms": integral(entry.timeout_ms),
        "on_ask": entry.on_ask,
        "origin": entry.origin,
        "order": entry.order,
    });
    if let Some(matcher) = &entry.matcher {
        out["matcher"] = json!(matcher);
    }
    if let Some(path) = &entry.path {
        out["path"] = json!(path);
    }
    out
}

fn row_from(value: &Value) -> seam::Row {
    let field = |name: &str| value.get(name).and_then(Value::as_str).unwrap_or_default();
    seam::Row {
        name: field("name").to_string(),
        event: field("event").to_string(),
        kind: field("kind").to_string(),
        origin: field("origin").to_string(),
        status: field("status").to_string(),
        timeout_ms: value.get("timeout_ms").and_then(Value::as_f64).unwrap_or(0.0),
        at: value.get("at").and_then(Value::as_u64).unwrap_or(0),
        exit_code: value.get("exit_code").and_then(Value::as_i64).map(|code| code as i32),
        stdout: value.get("stdout").and_then(Value::as_str).map(|text| text.as_bytes().to_vec()),
        stderr: value.get("stderr").and_then(Value::as_str).map(|text| text.as_bytes().to_vec()),
        json: value.get("json").and_then(Value::as_str).map(|text| text.as_bytes().to_vec()),
        ms: value.get("ms").and_then(Value::as_u64),
        error: value.get("error").and_then(Value::as_str).map(str::to_string),
        detail: value.get("detail").and_then(Value::as_str).map(str::to_string),
        stdout_clipped: flag(value, "stdout_clipped"),
        answered: flag(value, "answered"),
        system_message: value.get("system_message").and_then(Value::as_str).map(str::to_string),
    }
}

fn row_json(row: &seam::Row) -> Value {
    let mut out = json!({
        "name": row.name,
        "event": row.event,
        "kind": row.kind,
        "origin": row.origin,
        "status": row.status,
        "at": row.at,
    });
    // A Lua plugin entry has no timeout, so its row has none either (native leaves the field out).
    if row.timeout_ms > 0.0 {
        out["timeout_ms"] = integral(row.timeout_ms);
    }
    if let Some(code) = row.exit_code {
        out["exit_code"] = json!(code);
    }
    if let Some(stdout) = &row.stdout {
        out["stdout"] = json!(text(stdout));
    }
    if let Some(stderr) = &row.stderr {
        out["stderr"] = json!(text(stderr));
    }
    if let Some(body) = &row.json {
        out["json"] = json!(text(body));
    }
    if let Some(ms) = row.ms {
        out["ms"] = json!(ms);
    }
    if let Some(error) = &row.error {
        out["error"] = json!(error);
    }
    if let Some(detail) = &row.detail {
        out["detail"] = json!(detail);
    }
    if row.stdout_clipped {
        out["stdout_clipped"] = json!(true);
    }
    if row.answered {
        out["answered"] = json!(true);
    }
    if let Some(message) = &row.system_message {
        out["system_message"] = json!(message);
    }
    out
}

fn decision_from(value: &Value) -> seam::Decision {
    let field = |name: &str| value.get(name).and_then(Value::as_str).unwrap_or_default().to_string();
    seam::Decision {
        version: value.get("version").and_then(Value::as_u64).unwrap_or(1) as u32,
        event: field("event"),
        ran: value.get("ran").and_then(Value::as_u64).unwrap_or(0) as u32,
        outcomes: value
            .get("outcomes")
            .and_then(Value::as_array)
            .map(|rows| rows.iter().map(row_from).collect())
            .unwrap_or_default(),
        errors: value
            .get("errors")
            .and_then(Value::as_array)
            .map(|errors| {
                errors
                    .iter()
                    .map(|error| seam::DecisionError {
                        name: error.get("name").and_then(Value::as_str).map(str::to_string),
                        error: error.get("error").and_then(Value::as_str).unwrap_or_default().to_string(),
                        detail: error.get("detail").and_then(Value::as_str).map(str::to_string),
                    })
                    .collect()
            })
            .unwrap_or_default(),
        notes: strings(value, "notes"),
        system_messages: strings(value, "system_messages"),
        blocked: flag(value, "blocked"),
        status: field("status"),
        additional_context: value.get("additional_context").and_then(Value::as_str).map(str::to_string),
        updated_input_json: value
            .get("updated_input")
            .map(|value| serde_json::to_string(value).unwrap_or_else(|_| "{}".to_string()))
            .unwrap_or_else(|| "{}".to_string()),
        input_changes_json: value
            .get("input_changes")
            .map(|value| serde_json::to_string(value).unwrap_or_else(|_| "{}".to_string()))
            .unwrap_or_else(|| "{}".to_string()),
        permission: value.get("permission").and_then(Value::as_str).map(str::to_string),
        allowed_by: value.get("allowed_by").and_then(Value::as_str).map(str::to_string),
        blocked_by: value.get("blocked_by").and_then(Value::as_str).map(str::to_string),
        reason: value.get("reason").and_then(Value::as_str).map(str::to_string),
        stop: flag(value, "stop"),
        stop_reason: value.get("stop_reason").and_then(Value::as_str).map(str::to_string),
        reschedule_seconds: value.get("reschedule_seconds").and_then(Value::as_u64),
        text: value.get("text").and_then(Value::as_str).map(str::to_string),
    }
}

fn strings(value: &Value, field: &str) -> Vec<String> {
    value
        .get(field)
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default()
}

/// A decision as the native `M.fire` answers it: the fields native always sets are always present,
/// and the ones native leaves `nil` are absent (never `null`, which a Lua caller would see as a
/// truthy sentinel).
fn decision_json(decision: &seam::Decision) -> Value {
    let updated: Value =
        serde_json::from_str(&decision.updated_input_json).unwrap_or_else(|_| Value::Object(Map::new()));
    let changes: Value =
        serde_json::from_str(&decision.input_changes_json).unwrap_or_else(|_| Value::Object(Map::new()));
    let mut out = json!({
        "version": decision.version,
        "event": decision.event,
        "ran": decision.ran,
        "outcomes": decision.outcomes.iter().map(row_json).collect::<Vec<_>>(),
        "errors": decision.errors.iter().map(|error| {
            let mut row = json!({"error": error.error});
            if let Some(name) = &error.name { row["name"] = json!(name); }
            if let Some(detail) = &error.detail { row["detail"] = json!(detail); }
            row
        }).collect::<Vec<_>>(),
        "notes": decision.notes,
        "system_messages": decision.system_messages,
        "blocked": decision.blocked,
        "status": decision.status,
        "updated_input": updated,
        "input_changes": changes,
    });
    if let Some(value) = &decision.additional_context {
        out["additional_context"] = json!(value);
    }
    if let Some(value) = &decision.permission {
        out["permission"] = json!(value);
    }
    if let Some(value) = &decision.allowed_by {
        out["allowed_by"] = json!(value);
    }
    if let Some(value) = &decision.blocked_by {
        out["blocked_by"] = json!(value);
    }
    if let Some(value) = &decision.reason {
        out["reason"] = json!(value);
    }
    if decision.stop {
        out["stop"] = json!(true);
    }
    if let Some(value) = &decision.stop_reason {
        out["stop_reason"] = json!(value);
    }
    if let Some(value) = decision.reschedule_seconds {
        out["reschedule_seconds"] = json!(value);
    }
    if let Some(value) = &decision.text {
        out["text"] = json!(value);
    }
    out
}

fn config_request(request: &Value) -> seam::ConfigRequest {
    let sources = request
        .get("sources")
        .and_then(Value::as_array)
        .map(|sources| {
            sources
                .iter()
                .map(|source| seam::Source {
                    name: text_field(source, "name"),
                    path: text_field(source, "path"),
                    kind: text_field(source, "kind"),
                    text: optional_bytes(source, "text"),
                    problem: source.get("problem").and_then(Value::as_str).map(str::to_string),
                })
                .collect()
        })
        .unwrap_or_default();
    seam::ConfigRequest {
        workdir: text_field(request, "workdir"),
        disabled: flag(request, "disabled"),
        claude_env_opt_in: flag(request, "claude_env_opt_in"),
        sources,
    }
}

fn config_json(facts: &seam::ConfigFacts) -> Value {
    let mut hooks = Map::new();
    for event in &facts.hooks {
        hooks.insert(event.event.clone(), json!(event.entries.iter().map(entry_json).collect::<Vec<_>>()));
    }
    json!({
        "disabled": facts.disabled,
        "present": facts.present,
        "compat": facts.compat,
        "workdir": facts.workdir,
        "sources": facts.sources.iter().map(|source| json!({
            "name": source.name, "path": source.path, "kind": source.kind,
        })).collect::<Vec<_>>(),
        "errors": facts.errors,
        "hooks": hooks,
        "mods": {
            "statusline": facts.statusline.iter().map(entry_json).collect::<Vec<_>>(),
            // The native mods.commands row carries no `event`/`kind`/`command` difference from an
            // event entry beyond what it has: name, description, command, timeout_ms, origin.
            "commands": facts.commands.iter().map(|command| json!({
                "name": command.name,
                "description": command.description,
                "command": command.command,
                "timeout_ms": integral(command.timeout_ms),
                "origin": command.origin,
            })).collect::<Vec<_>>(),
            "keybindings": facts.keybindings.iter().map(|key| json!({
                "key": key.key, "command": key.command,
                "description": key.description, "origin": key.origin,
            })).collect::<Vec<_>>(),
        },
    })
}

fn bounds_json(bounds: &seam::Bounds) -> Value {
    json!({
        "version": bounds.version,
        "default_timeout_ms": bounds.default_timeout_ms,
        "max_timeout_ms": bounds.max_timeout_ms,
        "max_stdout_bytes": bounds.max_stdout_bytes,
        "max_stderr_bytes": bounds.max_stderr_bytes,
        "max_context_bytes": bounds.max_context_bytes,
        "max_system_messages": bounds.max_system_messages,
        "max_system_message_bytes": bounds.max_system_message_bytes,
        "max_stop_continues": bounds.max_stop_continues,
        "statusline_ttl_ms": bounds.statusline_ttl_ms,
        "statusline_timeout_ms": bounds.statusline_timeout_ms,
        "statusline_max": bounds.statusline_max,
        "last_kept": bounds.last_kept,
    })
}

fn event_json(event: &seam::EventFacts) -> Value {
    json!({
        "name": event.name,
        "matcher": event.matcher,
        "may": event.may,
        "when": event.when,
        "fields": event.fields,
    })
}

// ------------------------------------------------------------------------------------ the op table

fn invoke(store: &mut Store<State>, bindings: &HooksComponent, op: &str, request: &Value) -> Result<Value, String> {
    let seam = bindings.wa_hooks_hooks();
    match op {
        "catalogue" => {
            let events = seam.call_catalogue(&mut *store).map_err(|trap| trap_error("catalogue", &trap))?;
            let bounds = seam.call_engine_bounds(&mut *store).map_err(|trap| trap_error("bounds", &trap))?;
            Ok(json!({"ok": true, "op": op, "result": {
                "events": events.iter().map(event_json).collect::<Vec<_>>(),
                "bounds": bounds_json(&bounds),
            }}))
        }
        "configure" => {
            let facts = seam
                .call_configure(store, &config_request(request))
                .map_err(|trap| trap_error("configure", &trap))?
                .map_err(|error| seam_error(op, error))?;
            Ok(json!({"ok": true, "op": op, "result": config_json(&facts)}))
        }
        "entries" => {
            let entries = request
                .get("entries")
                .and_then(Value::as_array)
                .map(|entries| entries.iter().map(entry_from).collect())
                .unwrap_or_default();
            let request = seam::EntriesRequest {
                event: text_field(request, "event"),
                tool: request.get("tool").and_then(Value::as_str).map(str::to_string),
                entries,
            };
            let matched = seam
                .call_entries(store, &request)
                .map_err(|trap| trap_error("entries", &trap))?
                .map_err(|error| seam_error(op, error))?;
            Ok(json!({"ok": true, "op": op, "result": matched.iter().map(entry_json).collect::<Vec<_>>()}))
        }
        "decide" => {
            let request = seam::DecideRequest {
                event: text_field(request, "event"),
                payload: bytes_field(request, "payload"),
                prior: request.get("prior").map(decision_from),
                entry: entry_from(request.get("entry").unwrap_or(&Value::Null)),
                row: row_from(request.get("row").unwrap_or(&Value::Null)),
            };
            let step = seam
                .call_decide(store, &request)
                .map_err(|trap| trap_error("decide", &trap))?
                .map_err(|error| seam_error(op, error))?;
            let mut out = json!({
                "decision": decision_json(&step.decision),
                "stop": step.stop,
            });
            // The rewritten payload only crosses when a hook actually rewrote it: the common step is
            // one row in, one verdict out.
            if let Some(payload) = &step.payload {
                out["payload"] = json!(text(payload));
            }
            Ok(json!({"ok": true, "op": op, "result": out}))
        }
        "segment" => {
            let entries = request
                .get("entries")
                .and_then(Value::as_array)
                .map(|entries| entries.iter().map(entry_from).collect())
                .unwrap_or_default();
            let rows = request
                .get("rows")
                .and_then(Value::as_array)
                .map(|rows| rows.iter().map(row_from).collect())
                .unwrap_or_default();
            let text = seam
                .call_segment(store, &seam::SegmentRequest { entries, rows })
                .map_err(|trap| trap_error("segment", &trap))?;
            Ok(json!({"ok": true, "op": op, "result": text}))
        }
        other => Err(format!("invalid_hooks_request:unknown_op:{other}")),
    }
}

/// A seam `error` value: the component refused the request (`refused:<why>`) or could not answer
/// (`failed:<why>`). Either way the Lua router logs the reason and runs the native path, so the word
/// "refused" here never means "a hook refused" — that is a decision, and it arrives as a decision.
fn seam_error(op: &str, error: seam::Error) -> String {
    match error {
        seam::Error::Refused(why) => format!("component_refused:{op}:{why}"),
        seam::Error::Failed(why) => format!("component_failed:{op}:{why}"),
    }
}

/// The call itself failed (a trap, the epoch deadline, a missing export). Reported apart from a seam
/// error, so "the component stopped answering" never reads as "the engine said no".
fn trap_error(op: &str, error: &wasmtime::Error) -> String {
    let detail = error.to_string().lines().next().unwrap_or_default().to_string();
    let chain = format!("{error:?}").to_ascii_lowercase();
    let wedged = chain.contains("interrupt") || chain.contains("epoch deadline") || chain.contains("deadline reached");
    let kind = if wedged { "component_wedged" } else { "component_failed" };
    format!("{kind}:{op}:{detail}")
}

#[cfg(test)]
mod tests;
