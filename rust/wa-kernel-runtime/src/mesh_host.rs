//! The mesh seam, served: `wa:mesh` in a component, the transport in the kernel.
//!
//! This is the kernel half of `docs/CORE-SPLIT.md`'s fourth extraction. It loads the installed `mesh`
//! component, keeps one instance for the process (a decision is a pure function, so an instance holds
//! nothing worth dropping), calls one seam function, and turns the typed answer into the JSON the
//! routing layer (`wa_mesh::seam`) consumes. `WA_MESH_COMPONENT=1` routes there; the native path stays
//! the default and is the code `wa-mesh` always ran.
//!
//! What the component is *not* given, on purpose: `wa:kernel/sql` (the mesh stores no rows), a socket
//! (the listener and the relay are the kernel's), a clock (`now` is an argument), a path, and the node's
//! key. The world in `wit/mesh/mesh.wit` imports nothing at all, so an installed `mesh.wasm` grants
//! nothing and there is no scope for a manifest mistake to widen.
//!
//! Three rules this module is the place for, the ones `memory_host`/`selfloop_host` set:
//!
//! 1. **A refusal is an answer, not a failure.** A roster that does not verify comes back as `refused`
//!    with the native sentence, and the router returns it unchanged; only `ok: false` means the
//!    component could not answer, and then the router logs one line per (operation, reason) and runs
//!    the native path. A tampered roster must never read as a broken component.
//! 2. **A wedged guest never takes the node with it.** Every call re-arms an epoch deadline, and a trap
//!    drops the cached instance: a decision that cannot be made is retried natively, on this call.
//! 3. **The answer is the same text.** The audit line and the refusal sentence cross this boundary as
//!    the strings the native path would have produced, so `scripts/test-mesh-component.sh` can compare
//!    them field for field.
use crate::components::{compiled, component_dir, load_in, Installed};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use wasmtime::component::{Linker, ResourceTable};
use wasmtime::{Store, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

/// The installed name this seam is served from (`<components>/mesh.wasm`, `mesh.json`).
pub const COMPONENT: &str = "mesh";
/// How long one seam call may take end to end. A decision is a hash and a signature check over a
/// document of a few kilobytes; a component that has not answered by then is wedged.
const DEFAULT_TIMEOUT_MS: u64 = 2_000;
/// The component's own memory cap, from `limits.memory_mb` in its manifest when present.
const DEFAULT_MEMORY_MB: u64 = 32;
/// One engine tick is this long (`components::engine`'s ticker), so a deadline is counted in ticks.
const TICK_MS: u64 = 10;

wasmtime::component::bindgen!({
    path: "../../wit/mesh",
    world: "mesh-component",
});

use wa::mesh::types as seam;

/// Where one call gets what it needs: the components directory (or an explicit artifact) and the call's
/// deadline. A value rather than ambient environment, so a test can point two calls at two artifacts.
#[derive(Clone, Debug)]
pub struct Config {
    pub components_dir: PathBuf,
    /// `WA_MESH_COMPONENT_WASM`: an artifact from this checkout instead of the pinned install.
    pub wasm: Option<PathBuf>,
    /// `WA_MESH_COMPONENT_MANIFEST`: the manifest that goes with `wasm`.
    pub manifest: Option<PathBuf>,
    pub timeout_ms: u64,
    /// `WA_MESH_COMPONENT_INSTANCE`: `thread` (default) keeps one instance per thread, `call`
    /// instantiates per call. `scripts/bench-mesh.sh` measures the first call and the steady state.
    pub instance: Instance,
}

/// How an instance is held.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Instance {
    /// One instance **per thread**, reused for that thread's calls.
    ///
    /// Per thread, not per process: a wasmtime `Store` is a process's guest state, but the mesh is
    /// called from the listener's handler threads, the relay hop and the node's own thread at once, and
    /// a single store shared behind one lock was measured to hang the four-node relay test (one process,
    /// four nodes, several listener threads: `tests_relay.rs`) about half the time. A thread's instance
    /// is a thread's to use, and the seam holds no state that two threads would want to share.
    Thread,
    /// One instance per call: what `selfloop_host` does, kept selectable so the cost of the difference
    /// is a measurement rather than an opinion.
    PerCall,
}

impl Config {
    pub fn from_env() -> Config {
        let env_path = |key: &str| std::env::var(key).ok().filter(|value| !value.is_empty()).map(PathBuf::from);
        Config {
            components_dir: component_dir(),
            wasm: env_path("WA_MESH_COMPONENT_WASM"),
            manifest: env_path("WA_MESH_COMPONENT_MANIFEST"),
            timeout_ms: std::env::var("WA_MESH_COMPONENT_TIMEOUT_MS")
                .ok()
                .and_then(|value| value.parse::<u64>().ok())
                .filter(|value| *value > 0)
                .unwrap_or(DEFAULT_TIMEOUT_MS),
            instance: match std::env::var("WA_MESH_COMPONENT_INSTANCE").as_deref().map(str::trim) {
                Ok("call") => Instance::PerCall,
                _ => Instance::Thread,
            },
        }
    }

    pub fn with_components(mut self, dir: impl Into<PathBuf>) -> Config {
        self.components_dir = dir.into();
        self
    }

    pub fn with_artifact(mut self, wasm: impl Into<PathBuf>, manifest: impl Into<PathBuf>) -> Config {
        self.wasm = Some(wasm.into());
        self.manifest = Some(manifest.into());
        self
    }
}

/// The store's data: a WASI view (`std` in a `cdylib` still imports `wasi:cli`/`io`/`clocks`) and the
/// store's limits. No session, no scope: this component is granted nothing.
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

/// One live instance: the store it runs in and the bindings bound to it.
struct Served {
    store: Store<State>,
    bindings: MeshComponent,
    /// Which artifact this instance came from, so a pin change is a new instance rather than a stale
    /// one answering with yesterday's bytes.
    sha256: String,
}

thread_local! {
    /// This thread's instance. One per thread, because a `Store` is not something to move between
    /// threads behind a lock (see [`Instance::Thread`]); it holds nothing, so a node with eight handler
    /// threads has eight copies of a guest that remembers nothing.
    static SERVED: std::cell::RefCell<Option<Served>> = const { std::cell::RefCell::new(None) };
}

/// The component this call runs: the pinned install, or — for a checkout that built it itself — the
/// artifact `WA_MESH_COMPONENT_WASM` names. That override bypasses the components directory *and its
/// pin*: it is the development path `scripts/test-mesh-component.sh` uses.
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
            PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../components/mesh/manifest.json"))
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

/// Whether the mesh component is installed and loadable — what the router asks before routing, so a
/// missing component is a decision it makes once, with a reason, instead of a failed call per decision.
pub fn available() -> Result<String, String> {
    let config = Config::from_env();
    component(&config).map_err(|error| format!("component_unavailable:{error}")).map(|installed| installed.sha256)
}

/// One seam call: `{"op": …, …}` in, one of three answers out.
///
/// * `{"ok":true,"op":…,"result":…}` — the seam's answer, in the shape the native function returns;
/// * `{"ok":true,"op":…,"refused":…}` — the seam refused (a roster that does not verify, an attestation
///   that is not this call's), in the native vocabulary;
/// * `{"ok":false,"op":…,"error":…}` — the component could not answer (`component_not_installed`,
///   `component_wedged`, …). The router logs one line and runs the native path.
pub fn call(request: &Value) -> Value {
    call_with(&Config::from_env(), request)
}

pub fn call_with(config: &Config, request: &Value) -> Value {
    let op = request.get("op").and_then(Value::as_str).unwrap_or_default().to_string();
    let started = Instant::now();
    match dispatch(config, &op, request) {
        Ok(mut answer) => {
            answer["elapsed_ms"] = json!(started.elapsed().as_millis() as u64);
            answer
        }
        Err(error) => json!({"ok": false, "op": op, "error": error}),
    }
}

fn dispatch(config: &Config, op: &str, request: &Value) -> Result<Value, String> {
    let installed = component(config).map_err(|error| format!("component_unavailable:{error}"))?;
    match config.instance {
        Instance::Thread => held(&installed, config, op, request),
        Instance::PerCall => {
            let engine = crate::components::engine().map_err(|error| format!("component_engine:{error}"))?;
            let mut served = fresh(&engine, &installed, config.timeout_ms)?;
            invoke(&mut served, op, request)
        }
    }
}

fn fresh(engine: &wasmtime::Engine, installed: &Installed, timeout_ms: u64) -> Result<Served, String> {
    let component = compiled(engine, &installed.sha256, &installed.bytes)
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
    let mut store = Store::new(engine, state);
    store.limiter(|state| &mut state.limits);
    store.set_epoch_deadline(timeout_ms.div_ceil(TICK_MS) + 1);
    let mut linker: Linker<State> = Linker::new(engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker).map_err(|error| format!("component_link_wasi:{error}"))?;
    let bindings = MeshComponent::instantiate(&mut store, &component, &linker)
        // A component that imports an interface this host does not serve fails here, visibly: a link
        // error is a deployment mistake, not "the fleet says no".
        .map_err(|error| format!("component_instantiate:{error}"))?;
    Ok(Served { store, bindings, sha256: installed.sha256.clone() })
}

/// This thread's path: reuse the instance when it is the same artifact, else build one. A trap drops it,
/// so the next call starts from a clean guest instead of a poisoned one.
fn held(installed: &Installed, config: &Config, op: &str, request: &Value) -> Result<Value, String> {
    SERVED.with(|slot| {
        let mut held = slot.borrow_mut();
        if held.as_ref().map(|served| served.sha256 != installed.sha256).unwrap_or(true) {
            let engine = crate::components::engine().map_err(|error| format!("component_engine:{error}"))?;
            *held = Some(fresh(&engine, installed, config.timeout_ms)?);
        }
        let mut served = held.take().expect("just filled");
        // Re-arm the deadline: the store is reused, the budget is per call.
        served.store.set_epoch_deadline(config.timeout_ms.div_ceil(TICK_MS) + 1);
        match invoke(&mut served, op, request) {
            Ok(answer) => {
                // Put it back before returning: the *next* call on this thread reuses it.
                *held = Some(served);
                Ok(answer)
            }
            Err(error) => {
                // The instance is not reused after a trap: a guest that ran out of epoch leaves its own
                // state unattested, and the next call's native fallback is better than a maybe.
                drop(served);
                Err(error)
            }
        }
    })
}

// ------------------------------------------------------------------------------------ the op table

fn text_field(request: &Value, field: &str) -> String {
    request.get(field).and_then(Value::as_str).unwrap_or_default().to_string()
}

fn optional(request: &Value, field: &str) -> Option<String> {
    request.get(field).and_then(Value::as_str).map(str::to_string).filter(|value| !value.is_empty())
}

fn number(request: &Value, field: &str) -> u64 {
    request.get(field).and_then(Value::as_u64).unwrap_or(0)
}

fn flag(request: &Value, field: &str) -> bool {
    request.get(field).and_then(Value::as_bool).unwrap_or(false)
}

fn level(request: &Value, field: &str) -> Option<u8> {
    request.get(field).and_then(Value::as_u64).map(|value| value.min(255) as u8)
}

fn node_of(value: Option<&Value>) -> seam::Node {
    let value = value.cloned().unwrap_or(Value::Null);
    seam::Node {
        id: text_field(&value, "id"),
        public_key: text_field(&value, "public_key"),
        name: text_field(&value, "name"),
        level: level(&value, "level").unwrap_or(0),
        addresses: strings(&value, "addresses"),
        revoked_at: number(&value, "revoked_at"),
    }
}

fn strings(value: &Value, field: &str) -> Vec<String> {
    value
        .get(field)
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(|item| item.as_str().map(str::to_string)).collect())
        .unwrap_or_default()
}

fn grants(request: &Value) -> Vec<seam::Grant> {
    request
        .get("grants")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .map(|item| seam::Grant {
                    caller: text_field(item, "caller"),
                    target: text_field(item, "target"),
                    verb: text_field(item, "verb"),
                    effect: text_field(item, "effect"),
                    note: optional(item, "note"),
                })
                .collect()
        })
        .unwrap_or_default()
}

fn audit_event(request: &Value) -> seam::AuditEvent {
    let event = request.get("event").cloned().unwrap_or(Value::Null);
    seam::AuditEvent {
        kind: text_field(&event, "kind"),
        from_node: text_field(&event, "from"),
        to_node: text_field(&event, "to"),
        from_level: level(&event, "from_level"),
        to_level: level(&event, "to_level"),
        verb: text_field(&event, "verb"),
        decision: text_field(&event, "decision"),
        reason: text_field(&event, "reason"),
        transport: text_field(&event, "transport"),
        addr_class: text_field(&event, "addr_class"),
        ok: flag(&event, "ok"),
        status: event.get("status").and_then(Value::as_u64).map(|value| value.min(65535) as u16),
        ms: number(&event, "ms"),
        attempt: number(&event, "attempt").min(u32::MAX as u64) as u32,
    }
}

fn invoke(served: &mut Served, op: &str, request: &Value) -> Result<Value, String> {
    let Served { store, bindings, .. } = served;
    let mesh = bindings.wa_mesh_mesh();
    let st = &mut *store;
    match op {
        "verify_roster" => {
            let answer = mesh
                .call_verify_roster(&mut *st, &text_field(request, "document"), &text_field(request, "key"), number(request, "now"))
                .map_err(|error| trap_error(op, &error))?;
            Ok(match answer {
                Ok(facts) => json!({"ok": true, "op": op, "result": {
                    "fleet": facts.fleet,
                    "fingerprint": facts.fingerprint,
                    "issued_at": facts.issued_at,
                    "expires_at": facts.expires_at,
                    "levels": facts.nodes.iter().map(|node| json!({
                        "id": node.id,
                        "name": node.name,
                        "level": node.level,
                        "public_key": node.public_key,
                        "revoked_at": node.revoked_at,
                        "addresses": node.addresses,
                    })).collect::<Vec<_>>(),
                }}),
                Err(refusal) => json!({"ok": true, "op": op, "refused": refusal_json(&refusal)}),
            })
        }
        "decide" => {
            let facts = seam::CallFacts {
                caller: node_of(request.get("caller")),
                target: node_of(request.get("target")),
                verb: text_field(request, "verb"),
                now: number(request, "now"),
            };
            let verdict = mesh
                .call_decide(&mut *st, &grants(request), &facts)
                .map_err(|error| trap_error(op, &error))?;
            Ok(json!({"ok": true, "op": op, "result": {
                "allow": verdict.allow,
                "reason": verdict.reason,
                "detail": verdict.detail,
            }}))
        }
        "verb" => {
            let verb = mesh
                .call_verb(&mut *st, &text_field(request, "capability"))
                .map_err(|error| trap_error(op, &error))?;
            Ok(json!({"ok": true, "op": op, "result": verb}))
        }
        "render_audit" => {
            let line = mesh
                .call_render_audit(&mut *st, &audit_event(request))
                .map_err(|error| trap_error(op, &error))?;
            Ok(json!({"ok": true, "op": op, "result": line}))
        }
        "attest_message" => {
            let line = mesh
                .call_attest_message(
                    &mut *st,
                    &text_field(request, "node_id"),
                    &text_field(request, "caller"),
                    &text_field(request, "verb"),
                    &text_field(request, "capability"),
                    &text_field(request, "caller_signature"),
                    number(request, "ts"),
                )
                .map_err(|error| trap_error(op, &error))?;
            Ok(json!({"ok": true, "op": op, "result": line}))
        }
        "verify_ticket" => {
            let ticket = request.get("ticket").cloned().unwrap_or(Value::Null);
            let answer = mesh
                .call_verify_ticket(
                    &mut *st,
                    &seam::Ticket {
                        caller: text_field(&ticket, "caller"),
                        verb: text_field(&ticket, "verb"),
                        capability: text_field(&ticket, "capability"),
                        ts: number(&ticket, "ts"),
                        signature: text_field(&ticket, "signature"),
                    },
                    &text_field(request, "node_id"),
                    &text_field(request, "node_public_key"),
                    &text_field(request, "caller_signature"),
                    number(request, "now"),
                )
                .map_err(|error| trap_error(op, &error))?;
            Ok(match answer {
                Ok(facts) => json!({"ok": true, "op": op, "result": {
                    "node_id": facts.node_id,
                    "caller": facts.caller,
                    "verb": facts.verb,
                    "capability": facts.capability,
                    "ts": facts.ts,
                }}),
                Err(refusal) => json!({"ok": true, "op": op, "refused": ticket_refusal_json(&refusal)}),
            })
        }
        "addresses" => {
            let target = node_of(request.get("target"));
            let learned: Vec<String> = request
                .get("learned")
                .and_then(Value::as_array)
                .map(|items| items.iter().filter_map(|item| item.as_str().map(str::to_string)).collect())
                .unwrap_or_default();
            let addresses = mesh
                .call_addresses(&mut *st, &target, &learned)
                .map_err(|error| trap_error(op, &error))?;
            Ok(json!({"ok": true, "op": op, "result": addresses}))
        }
        other => Err(format!("invalid_mesh_request:unknown_op:{other}")),
    }
}

/// One roster refusal, in the words the native path answers with: `RosterProblem::sentence()` is the
/// inverse of the parser's classification, so an operator reads one vocabulary for one mistake.
fn refusal_json(refusal: &seam::RosterRefusal) -> Value {
    use seam::RosterRefusal as R;
    let problem = match refusal {
        R::NotARoster(text) => wa_mesh_core::roster::RosterProblem::NotARoster(text.clone()),
        R::KeyMissing => wa_mesh_core::roster::RosterProblem::KeyMissing,
        R::KeyMalformed(text) => wa_mesh_core::roster::RosterProblem::KeyMalformed(text.clone()),
        R::BadSignature => wa_mesh_core::roster::RosterProblem::BadSignature,
        R::NotYetValid => wa_mesh_core::roster::RosterProblem::NotYetValid,
        R::Expired => wa_mesh_core::roster::RosterProblem::Expired,
        R::VersionUnsupported(version) => wa_mesh_core::roster::RosterProblem::VersionUnsupported(*version),
        R::LevelOutOfRange(name) => wa_mesh_core::roster::RosterProblem::LevelOutOfRange(name.clone()),
        R::DuplicateNode(id) => wa_mesh_core::roster::RosterProblem::DuplicateNode(id.clone()),
        R::NodeIdMismatch(name) => wa_mesh_core::roster::RosterProblem::NodeIdMismatch(name.clone()),
        R::BadAddress(address) => wa_mesh_core::roster::RosterProblem::BadAddress(address.clone()),
        R::TooManyAddresses(name) => wa_mesh_core::roster::RosterProblem::TooManyAddresses(name.clone()),
        R::BadName(text) => wa_mesh_core::roster::RosterProblem::BadName(text.clone()),
    };
    json!({"error": problem.sentence()})
}

fn ticket_refusal_json(refusal: &seam::TicketRefusal) -> Value {
    use seam::TicketRefusal as R;
    match refusal {
        R::Absent => json!({"error": "attestation_absent"}),
        R::BadSignature => json!({"error": "attestation_bad_signature"}),
        R::Stale(age) => json!({"error": "attestation_stale", "age": age}),
        R::Mismatch(field) => json!({"error": wa_mesh_core::attest::mismatch_slug(field)}),
    }
}

/// The call itself failed (a trap, the epoch deadline, a missing export). Reported apart from the seam's
/// own refusals, so "the component stopped answering" never reads as "the fleet says no".
fn trap_error(op: &str, error: &wasmtime::Error) -> String {
    let detail = error.to_string().lines().next().unwrap_or_default().to_string();
    let chain = format!("{error:?}").to_ascii_lowercase();
    let wedged = chain.contains("interrupt") || chain.contains("epoch deadline") || chain.contains("deadline reached");
    let kind = if wedged { "component_wedged" } else { "component_failed" };
    format!("{kind}:{op}:{detail}")
}

/// `host.mesh(request_json)` -> the answer from [`call`]. One capability, one call, one seam operation:
/// the request names an operation and its facts, never a path, a key or a scope.
pub extern "C-unwind" fn capability(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => call(&request),
        Err(_) => json!({"ok": false, "error": "invalid_mesh_request:not_json"}),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

/// The deadline a pooled call re-arms, exposed for the benchmark's warm-up to read.
pub fn timeout() -> Duration {
    Duration::from_millis(Config::from_env().timeout_ms)
}
