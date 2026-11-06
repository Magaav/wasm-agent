//! WASI components: installable, sandboxed programs the core runs without being rebuilt.
//!
//! A component is a `wasm32-wasip2` command (`wasi:cli/run`) installed as three files in the
//! component directory (`WA_COMPONENTS_DIR`, default `~/.wasm-agent/components`):
//!
//!   <name>.wasm          the component
//!   <name>.wasm.sha256   its pin (required: an unpinned component is refused, unlike plugins)
//!   <name>.json          its manifest: what it declares it may need
//!
//! The manifest DECLARES capabilities; the caller (an MCP registry definition) GRANTS them; the
//! host gives the component exactly the grant, and refuses a grant the manifest did not declare.
//! Nothing else exists inside: no filesystem, no network, no inherited environment, no clock
//! beyond WASI's, a memory cap and an epoch deadline. Capabilities today:
//!
//!   env       {KEY: "HOST_ENV_NAME"}  the component sees KEY = value of the host variable
//!   file_env  {KEY: "HOST_ENV_NAME" | "/abs/path"}  the host reads that file (named directly or
//!                                     by a host variable); the component sees its contents
//!                                     (trimmed) as KEY. Secrets stay file references.
//!   net       ["127.0.0.1:28787"]     exact TCP socket addresses it may connect to
//!   dirs      [{"host":"/abs","guest":"/graph/root","write":false}]  a host directory preopened at
//!                                     the guest path; the manifest declares the guest paths
//!
//! `mcp()` speaks MCP JSON-RPC over the component's stdin/stdout, one request per run, and returns
//! the same answer shape as `scripts/mcp-client-core.mjs`, so the Lua MCP registry, tool schemas
//! and code mode treat a component server like any other. See docs/COMPONENTS.md.
use anyhow::{anyhow, Result};
use ring::digest::{digest, SHA256};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::net::{SocketAddr, ToSocketAddrs};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Config, Engine, Store, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::p2::pipe::{MemoryInputPipe, MemoryOutputPipe};
use wasmtime_wasi::sockets::SocketAddrUse;
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

const MEMORY_LIMIT: usize = 256 << 20;
const STDOUT_LIMIT: usize = 16 << 20;
const STDERR_LIMIT: usize = 64 << 10;
const STDIN_LIMIT: usize = 4 << 20;
const TICK: Duration = Duration::from_millis(10);
const MAX_TIMEOUT_MS: u64 = 600_000;
const PROTOCOL: &str = "2025-11-25";

fn hex(bytes: &[u8]) -> String {
    digest(&SHA256, bytes).as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

pub fn component_dir() -> PathBuf {
    if let Ok(path) = std::env::var("WA_COMPONENTS_DIR") {
        return PathBuf::from(path);
    }
    let home = std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")).unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".wasm-agent").join("components")
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 40
        && name.bytes().next().is_some_and(|b| b.is_ascii_lowercase())
        && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// One engine for every component: component model on, epoch interruption for the deadline, and a
/// single ticker thread that advances the epoch.
pub(crate) fn engine() -> Result<Engine> {
    static ENGINE: OnceLock<Engine> = OnceLock::new();
    if let Some(engine) = ENGINE.get() {
        return Ok(engine.clone());
    }
    let mut config = Config::new();
    config.wasm_component_model(true);
    config.epoch_interruption(true);
    let engine = Engine::new(&config)?;
    if ENGINE.set(engine.clone()).is_ok() {
        let ticker = engine.clone();
        std::thread::Builder::new()
            .name("wa-component-epoch".into())
            .spawn(move || loop {
                std::thread::sleep(TICK);
                ticker.increment_epoch();
            })?;
    }
    Ok(ENGINE.get().expect("engine initialized").clone())
}

/// Compiled components by content hash: compiling is the expensive step, a pin change is a new key.
fn compiled(engine: &Engine, sha: &str, bytes: &[u8]) -> Result<Component> {
    static CACHE: OnceLock<Mutex<HashMap<String, Component>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some(found) = cache.lock().map_err(|_| anyhow!("component_cache_poisoned"))?.get(sha) {
        return Ok(found.clone());
    }
    let component = disk_cached(engine, sha, bytes)?;
    cache.lock().map_err(|_| anyhow!("component_cache_poisoned"))?.insert(sha.to_string(), component.clone());
    Ok(component)
}

/// Compiled code across processes: a large component (the graph is ~8 MB: tree-sitter grammars)
/// takes seconds to compile, and every `wa` invocation is a new process. Keyed by the pin and this
/// engine's compatibility hash, in the node's own `~/.wasm-agent/cache/components`. `WA_COMPONENT_CACHE=0` disables it.
fn disk_cached(engine: &Engine, sha: &str, bytes: &[u8]) -> Result<Component> {
    use std::hash::{Hash, Hasher};
    if std::env::var("WA_COMPONENT_CACHE").map_or(false, |v| v == "0") {
        return Ok(Component::new(engine, bytes)?);
    }
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    engine.precompile_compatibility_hash().hash(&mut hasher);
    let home = std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")).unwrap_or_else(|_| ".".into());
    let dir = PathBuf::from(home).join(".wasm-agent").join("cache").join("components");
    let path = dir.join(format!("{sha}-{:016x}.cwasm", hasher.finish()));
    if path.is_file() {
        // Safety: written below by this binary from bytes whose sha256 is the key, for an engine
        // with this compatibility hash, in the node's private directory.
        if let Ok(component) = unsafe { Component::deserialize_file(engine, &path) } {
            return Ok(component);
        }
    }
    let component = Component::new(engine, bytes)?;
    if let Ok(serialized) = component.serialize() {
        let _ = std::fs::create_dir_all(&dir);
        let tmp = dir.join(format!(".{sha}.{}.tmp", std::process::id()));
        if std::fs::write(&tmp, serialized).is_ok() && std::fs::rename(&tmp, &path).is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    }
    Ok(component)
}

/// An installed component, read and verified against its pin.
pub struct Installed {
    pub name: String,
    pub sha256: String,
    pub bytes: Vec<u8>,
    pub manifest: Value,
}

pub fn load(name: &str) -> Result<Installed> {
    if !valid_name(name) {
        return Err(anyhow!("invalid_component_name"));
    }
    let dir = component_dir();
    let path = dir.join(format!("{name}.wasm"));
    let bytes = std::fs::read(&path).map_err(|_| anyhow!("component_not_installed:{name}"))?;
    let pin = std::fs::read_to_string(dir.join(format!("{name}.wasm.sha256")))
        .map_err(|_| anyhow!("component_pin_missing:{name}"))?;
    let declared = pin.split_whitespace().next().unwrap_or_default().to_ascii_lowercase();
    let actual = hex(&bytes);
    if declared != actual {
        return Err(anyhow!("component_hash_mismatch:{name}"));
    }
    let manifest = match std::fs::read_to_string(dir.join(format!("{name}.json"))) {
        Ok(text) => serde_json::from_str(&text).map_err(|_| anyhow!("component_manifest_invalid:{name}"))?,
        Err(_) => json!({}),
    };
    Ok(Installed { name: name.into(), sha256: actual, bytes, manifest })
}

/// What a caller grants, checked against what the manifest declares.
#[derive(Default, Debug)]
pub struct Grant {
    pub env: BTreeMap<String, String>,
    pub file_env: BTreeMap<String, String>,
    pub net: Vec<String>,
    /// Non-secret configuration (the registry definition's `config` object), as JSON text in
    /// `WA_COMPONENT_CONFIG`. Data, not a capability: it grants nothing.
    pub config: Option<String>,
    /// Preopened directories, each declared by its guest path in the manifest's `dirs`.
    pub dirs: Vec<DirGrant>,
}

#[derive(Debug, Clone)]
pub struct DirGrant {
    pub host: String,
    pub guest: String,
    pub write: bool,
}

/// An absolute file path (POSIX `/...` or Windows `C:\...` / `C:/...`). A path is a location, not a
/// secret: `file_env` may name the file directly instead of through a host variable.
fn absolute_path(value: &str) -> bool {
    let bytes = value.as_bytes();
    value.len() <= 4096
        && !value.contains(['\n', '\r', '\0'])
        && (value.starts_with('/') || (bytes.len() > 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && (bytes[2] == b'/' || bytes[2] == b'\\')))
}

fn string_map(value: Option<&Value>, field: &str) -> Result<BTreeMap<String, String>> {
    let mut out = BTreeMap::new();
    let Some(value) = value else { return Ok(out) };
    let object = value.as_object().ok_or_else(|| anyhow!("invalid_component_grant:{field}"))?;
    for (key, name) in object {
        let name = name.as_str().ok_or_else(|| anyhow!("invalid_component_grant:{field}"))?;
        let ok = |s: &str| !s.is_empty() && s.len() <= 128 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
        if !ok(key) || !(ok(name) || (field == "file_env" && absolute_path(name))) {
            return Err(anyhow!("invalid_component_grant:{field}"));
        }
        out.insert(key.clone(), name.to_string());
    }
    Ok(out)
}

impl Grant {
    pub fn from_request(request: &Value) -> Result<Grant> {
        let mut grant = Grant {
            env: string_map(request.get("env"), "env")?,
            file_env: string_map(request.get("file_env"), "file_env")?,
            net: Vec::new(),
            config: None,
            dirs: Vec::new(),
        };
        if let Some(list) = request.get("dirs") {
            for item in list.as_array().ok_or_else(|| anyhow!("invalid_component_grant:dirs"))? {
                let host = item.get("host").and_then(Value::as_str).unwrap_or_default();
                let guest = item.get("guest").and_then(Value::as_str).unwrap_or_default();
                let guest_ok = guest.starts_with('/') && guest.len() <= 128 && !guest.contains("..")
                    && guest.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'_' | b'-' | b'.'));
                if !absolute_path(host) || !guest_ok || grant.dirs.len() >= 8 {
                    return Err(anyhow!("invalid_component_grant:dirs"));
                }
                let write = item.get("write").and_then(Value::as_bool).unwrap_or(false);
                grant.dirs.push(DirGrant { host: host.to_string(), guest: guest.to_string(), write });
            }
        }
        if let Some(config) = request.get("config") {
            if !config.is_object() {
                return Err(anyhow!("invalid_component_grant:config"));
            }
            let text = config.to_string();
            if text.len() > 64 * 1024 {
                return Err(anyhow!("invalid_component_grant:config"));
            }
            grant.config = Some(text);
        }
        if let Some(list) = request.get("net") {
            for item in list.as_array().ok_or_else(|| anyhow!("invalid_component_grant:net"))? {
                let addr = item.as_str().ok_or_else(|| anyhow!("invalid_component_grant:net"))?;
                if addr.len() > 255 || grant.net.len() >= 16 {
                    return Err(anyhow!("invalid_component_grant:net"));
                }
                grant.net.push(addr.to_string());
            }
        }
        Ok(grant)
    }

    /// Every granted key/address must be declared by the manifest's `capabilities`.
    pub fn check(&self, manifest: &Value) -> Result<()> {
        let declared = |field: &str| -> Vec<String> {
            manifest
                .get("capabilities")
                .and_then(|c| c.get(field))
                .and_then(Value::as_array)
                .map(|list| list.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
                .unwrap_or_default()
        };
        for (field, keys) in [("env", self.env.keys().cloned().collect::<Vec<_>>()), ("file_env", self.file_env.keys().cloned().collect())] {
            let allowed = declared(field);
            if let Some(key) = keys.iter().find(|key| !allowed.contains(key)) {
                return Err(anyhow!("component_capability_not_declared:{field}:{key}"));
            }
        }
        let allowed = declared("dirs");
        if let Some(dir) = self.dirs.iter().find(|dir| !allowed.contains(&dir.guest)) {
            return Err(anyhow!("component_capability_not_declared:dirs:{}", dir.guest));
        }
        // "host:*" declares every port on that host (a loopback connector's port is per node).
        let allowed = declared("net");
        let covered = |addr: &String| {
            allowed.contains(addr)
                || addr.rsplit_once(':').is_some_and(|(host, _)| allowed.contains(&format!("{host}:*")))
        };
        if let Some(addr) = self.net.iter().find(|addr| !covered(addr)) {
            return Err(anyhow!("component_capability_not_declared:net:{addr}"));
        }
        Ok(())
    }
}

struct Ctx {
    wasi: WasiCtx,
    table: ResourceTable,
    limits: StoreLimits,
}

impl WasiView for Ctx {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

/// The outcome of one run. `stdout` is everything the component wrote, bounded.
pub struct Run {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    #[allow(dead_code)] // kept for service components; MCP reads responses, not the exit
    pub exit_ok: bool,
    pub error: Option<String>,
    pub elapsed_ms: u128,
}

/// Run an installed component once: `stdin` in, stdout/stderr out, within `timeout_ms`.
pub fn run(installed: &Installed, grant: &Grant, stdin: Vec<u8>, timeout_ms: u64) -> Result<Run> {
    grant.check(&installed.manifest)?;
    if stdin.len() > STDIN_LIMIT {
        return Err(anyhow!("component_input_too_large"));
    }
    let engine = engine()?;
    let component = compiled(&engine, &installed.sha256, &installed.bytes)?;
    let stdout = MemoryOutputPipe::new(STDOUT_LIMIT);
    let stderr = MemoryOutputPipe::new(STDERR_LIMIT);
    let mut builder = WasiCtxBuilder::new();
    builder.stdin(MemoryInputPipe::new(stdin));
    builder.stdout(stdout.clone());
    builder.stderr(stderr.clone());
    builder.args(&[installed.name.as_str()]);
    for (key, name) in &grant.env {
        if let Ok(value) = std::env::var(name) {
            builder.env(key, &value);
        }
    }
    if let Some(config) = &grant.config {
        builder.env("WA_COMPONENT_CONFIG", config);
    }
    for (key, name) in &grant.file_env {
        let path = if absolute_path(name) { name.clone() } else { std::env::var(name).map_err(|_| anyhow!("component_file_env_unset:{key}"))? };
        let value = std::fs::read_to_string(&path).map_err(|_| anyhow!("component_file_env_unreadable:{key}"))?;
        builder.env(key, value.trim());
    }
    for dir in &grant.dirs {
        // wasmtime 50: one FsPerms for the directory and its files.
        let perms = if dir.write { wasmtime_wasi::FsPerms::ReadWrite } else { wasmtime_wasi::FsPerms::ReadOnly };
        builder.preopened_dir(&dir.host, &dir.guest, perms).map_err(|_| anyhow!("component_dir_unavailable:{}", dir.guest))?;
    }
    if !grant.net.is_empty() {
        let mut allowed: Vec<SocketAddr> = Vec::new();
        for addr in &grant.net {
            allowed.extend(addr.to_socket_addrs().map_err(|_| anyhow!("component_net_unresolvable:{addr}"))?);
        }
        let allowed = Arc::new(allowed);
        builder.inherit_network();
        // Two wasmtime 37 → 50 behaviour changes meet here, both of which silently turned a granted
        // component network into "permission denied" (`Os { code: 2 }` in the guest, EACCES) until
        // `scripts/test-component-whatsapp-parity.mjs` caught it:
        //
        // 1. `WasiCtx`'s blanket TCP/UDP switch: 37 wrote `udp: true, tcp: true` into
        //    `AllowedNetworkUses::default()`, 50 derives the default, i.e. both are off, and
        //    `inherit_network` only sets the address check. A `net` grant is what used to make them
        //    usable, so the switch is set here and not left to the default.
        // 2. The check itself moved into the socket implementation and is now also asked about the
        //    *implicit* bind the OS performs during `connect`/`listen`, passing the wildcard address
        //    with port 0 (`SocketAddrUse::TcpBind`: "the wildcard address for implicit binds"); 37
        //    checked only the address the guest asked for. A grant names addresses to reach, not an
        //    ephemeral local port, so the wildcard-bind case is allowed - and only that case:
        //    `TcpConnect`, `TcpListen`, `TcpAccept` and the UDP uses keep the exact-match check, so
        //    this cannot widen what the guest reaches or what it may serve.
        builder.allow_tcp(true);
        builder.allow_udp(true);
        builder.allow_ip_name_lookup(false);
        let component = installed.name.clone();
        builder.socket_addr_check(move |addr, use_| {
            let implicit_bind = addr.port() == 0
                && addr.ip().is_unspecified()
                && matches!(use_, SocketAddrUse::TcpBind | SocketAddrUse::UdpBind);
            let granted = implicit_bind || allowed.contains(&addr);
            // The manifest grant is the boundary on this path; the node policy narrows it only
            // where the operator wrote a rule for this component (`docs/GRANT-POLICY.md`). A policy
            // file that names no rule for it must not turn a granted component into a refused one,
            // and a rule that does name it is enforced per address - the same check the wa:kernel
            // path makes, on the only outbound uses that leave the sandbox.
            let outbound = matches!(use_, SocketAddrUse::TcpConnect | SocketAddrUse::UdpSend);
            let permitted = granted
                && (!outbound
                    || crate::node_policy::check_if_ruled(&component, "net.dial", Some(&addr.to_string())).is_allow());
            Box::pin(async move { permitted })
        });
    }
    let limits = StoreLimitsBuilder::new().memory_size(MEMORY_LIMIT).instances(64).build();
    let mut store = Store::new(&engine, Ctx { wasi: builder.build(), table: ResourceTable::new(), limits });
    store.limiter(|ctx| &mut ctx.limits);
    let timeout_ms = timeout_ms.clamp(1, MAX_TIMEOUT_MS);
    store.set_epoch_deadline((timeout_ms / TICK.as_millis() as u64).max(1));
    let mut linker = Linker::<Ctx>::new(&engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker)?;
    // The run is one telemetry observation (docs/TELEMETRY.md): link, instantiate and the guest's
    // whole execution, attributed to the component. Recorded below, before the outcome is returned.
    let start_ms = crate::node_telemetry::now_ms();
    let started = Instant::now();
    let command = wasmtime_wasi::p2::bindings::sync::Command::instantiate(&mut store, &component, &linker)?;
    let outcome = command.wasi_cli_run().call_run(&mut store);
    let elapsed_ms = started.elapsed().as_millis();
    let (exit_ok, error) = match outcome {
        Ok(Ok(())) => (true, None),
        Ok(Err(())) => (false, Some("component_exit_failure".to_string())),
        Err(trap) => {
            let text = format!("{trap:?}");
            if text.contains("interrupt") || u128::from(timeout_ms) <= elapsed_ms {
                (false, Some("component_deadline".to_string()))
            } else if let Some(exit) = trap.downcast_ref::<wasmtime_wasi::I32Exit>() {
                (exit.0 == 0, (exit.0 != 0).then(|| format!("component_exit_{}", exit.0)))
            } else {
                (false, Some("component_trap".to_string()))
            }
        }
    };
    crate::node_telemetry::record_component_run(&installed.name, start_ms, started.elapsed().as_micros() as u64, exit_ok);
    drop(store);
    Ok(Run { stdout: stdout.contents().to_vec(), stderr: stderr.contents().to_vec(), exit_ok, error, elapsed_ms })
}

fn tail(bytes: &[u8], limit: usize) -> String {
    let start = bytes.len().saturating_sub(limit);
    String::from_utf8_lossy(&bytes[start..]).into_owned()
}

fn fail(error: &str, phase: &str, issued: bool) -> Value {
    json!({"ok": false, "error": error, "phase": phase, "tool_call_issued": issued, "outcome": if issued {"unknown"} else {"not_submitted"}})
}

/// One MCP request against a component: `probe` (initialize + tools/list) or `call` (initialize +
/// tools/call). The schema hash is the component's pinned sha256: the same bytes answer with the
/// same tools, so a changed component is refused before anything is sent to it.
pub fn mcp(request: &Value) -> Value {
    let action = request.get("action").and_then(Value::as_str).unwrap_or_default();
    let name = request.get("component").and_then(Value::as_str).unwrap_or_default();
    let installed = match load(name) {
        Ok(installed) => installed,
        Err(error) => return fail(&error.to_string(), "load", false),
    };
    let grant = match Grant::from_request(request) {
        Ok(grant) => grant,
        Err(error) => return fail(&error.to_string(), "grant", false),
    };
    let timeout_ms = request.get("timeout_seconds").and_then(Value::as_u64).unwrap_or(30).saturating_mul(1000);
    let mut lines = vec![
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":PROTOCOL,"capabilities":{},"clientInfo":{"name":"wasm-agent","version":"1"}}}),
        json!({"jsonrpc":"2.0","method":"notifications/initialized","params":{}}),
        json!({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}),
    ];
    let mut tool = String::new();
    match action {
        "probe" => {}
        "call" => {
            if let Some(expected) = request.get("schema_hash").and_then(Value::as_str) {
                if expected != installed.sha256 {
                    return fail("mcp_tool_schemas_changed", "load", false);
                }
            }
            tool = request.get("tool").and_then(Value::as_str).unwrap_or_default().to_string();
            let arguments = match request.get("arguments_json").and_then(Value::as_str) {
                Some(raw) => match serde_json::from_str::<Value>(raw) {
                    Ok(value) if value.is_object() => value,
                    _ => return fail("invalid_mcp_action", "arguments", false),
                },
                None => request.get("arguments").cloned().filter(Value::is_object).unwrap_or_else(|| json!({})),
            };
            if tool.is_empty() {
                return fail("invalid_mcp_action", "arguments", false);
            }
            lines.push(json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":tool,"arguments":arguments}}));
        }
        _ => return fail("invalid_mcp_action", "arguments", false),
    }
    let mut stdin = Vec::new();
    for line in &lines {
        stdin.extend(line.to_string().into_bytes());
        stdin.push(b'\n');
    }
    let issued = action == "call";
    let run = match run(&installed, &grant, stdin, timeout_ms) {
        Ok(run) => run,
        // Refused before instantiation (grant, compile, link): nothing reached the component.
        Err(error) => return fail(&error.to_string(), "start", false),
    };
    let mut responses: HashMap<i64, Value> = HashMap::new();
    for line in run.stdout.split(|b| *b == b'\n') {
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        if let Ok(value) = serde_json::from_slice::<Value>(line) {
            if let Some(id) = value.get("id").and_then(Value::as_i64) {
                responses.insert(id, value);
            }
        }
    }
    let with_run = |mut answer: Value| {
        answer["session_mode"] = json!("component");
        answer["component"] = json!(installed.name);
        answer["component_sha256"] = json!(installed.sha256);
        answer["elapsed_ms"] = json!(run.elapsed_ms as u64);
        if answer["ok"] == json!(false) && !run.stderr.is_empty() {
            answer["server_stderr_tail"] = json!(tail(&run.stderr, 2048));
        }
        if let Some(error) = &run.error {
            answer["component_exit"] = json!(error);
        }
        answer
    };
    let result_of = |id: i64, phase: &str| -> Result<Value, Value> {
        match responses.get(&id) {
            Some(response) if response.get("result").is_some() => Ok(response["result"].clone()),
            Some(response) => {
                let mut answer = fail("mcp_rpc_error", phase, false);
                answer["rpc_error"] = response.get("error").cloned().unwrap_or(Value::Null);
                Err(answer)
            }
            None => Err(fail(run.error.as_deref().unwrap_or("mcp_no_response"), phase, false)),
        }
    };
    let initialized = match result_of(1, "initialize") {
        Ok(value) => value,
        Err(answer) => return with_run(answer),
    };
    let listed = match result_of(2, "tools/list") {
        Ok(value) => value,
        Err(answer) => return with_run(answer),
    };
    let Some(tools) = listed.get("tools").and_then(Value::as_array) else {
        return with_run(fail("invalid_mcp_tool_list", "tools/list", false));
    };
    let tools: Vec<Value> = tools
        .iter()
        .map(|t| {
            let mut t = t.clone();
            t["input_schema_json"] = json!(t.get("inputSchema").cloned().unwrap_or_else(|| json!({"type":"object"})).to_string());
            t
        })
        .collect();
    let mut answer = json!({
        "ok": true,
        "protocol_version": initialized.get("protocolVersion").cloned().unwrap_or(Value::Null),
        "server_info": initialized.get("serverInfo").cloned().unwrap_or(Value::Null),
        "tools": tools,
        "schema_hash": installed.sha256,
        "tool_call_issued": false,
    });
    if !issued {
        return with_run(answer);
    }
    if !tools.iter().any(|t| t.get("name").and_then(Value::as_str) == Some(tool.as_str())) {
        // The call line was in stdin, but a conforming server answers an unknown tool with an
        // error and no effect.
        return with_run(fail("unknown_mcp_tool", "tools/call", false));
    }
    match responses.get(&3) {
        Some(response) if response.get("result").is_some() => {
            let result = response["result"].clone();
            answer["ok"] = json!(result.get("isError").and_then(Value::as_bool) != Some(true));
            // As mcp-client.mjs does: the result travels as exact JSON text, so Lua never
            // re-encodes it ({} stays {}, [] stays [], null stays null).
            answer["result_json"] = json!(result.to_string());
            answer["tool_call_issued"] = json!(true);
            with_run(answer)
        }
        Some(response) => {
            let mut answer = fail("mcp_rpc_error", "tools/call", false);
            answer["rpc_error"] = response.get("error").cloned().unwrap_or(Value::Null);
            with_run(answer)
        }
        None => with_run(fail(run.error.as_deref().unwrap_or("mcp_no_response"), "tools/call", true)),
    }
}

/// host.component_mcp(request_json) -> answer (see `mcp`).
pub extern "C-unwind" fn component_mcp(l: *mut crate::lua::LuaState) -> std::os::raw::c_int {
    let raw = crate::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => mcp(&request),
        Err(_) => fail("invalid_component_request", "arguments", false),
    };
    crate::host::push_json(l, &answer);
    1
}

/// host.components() -> installed components with their manifests and pin state.
pub extern "C-unwind" fn components(l: *mut crate::lua::LuaState) -> std::os::raw::c_int {
    let mut list = Vec::new();
    if let Ok(entries) = std::fs::read_dir(component_dir()) {
        let mut names: Vec<String> = entries
            .flatten()
            .filter_map(|e| e.file_name().to_str().and_then(|n| n.strip_suffix(".wasm")).map(str::to_string))
            .collect();
        names.sort();
        for name in names {
            match load(&name) {
                Ok(installed) => list.push(json!({"name": name, "sha256": installed.sha256, "manifest": installed.manifest, "ok": true})),
                Err(error) => list.push(json!({"name": name, "ok": false, "error": error.to_string()})),
            }
        }
    }
    crate::host::push_json(l, &json!(list));
    1
}

/// Tests that point WA_COMPONENTS_DIR somewhere hold this: the variable is process-wide.
#[cfg(test)]
pub(crate) static TEST_DIR_LOCK: Mutex<()> = Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grants_must_be_declared() {
        let manifest = json!({"capabilities": {"env": ["A"], "file_env": ["TOKEN"], "net": ["127.0.0.1:1"]}});
        let ok = Grant::from_request(&json!({"env": {"A": "HOME"}, "file_env": {"TOKEN": "X"}, "net": ["127.0.0.1:1"]})).unwrap();
        assert!(ok.check(&manifest).is_ok());
        let any = Grant::from_request(&json!({"net": ["[::1]:9"]})).unwrap();
        assert!(any.check(&json!({"capabilities": {"net": ["[::1]:*"]}})).is_ok());
        let wide = Grant::from_request(&json!({"net": ["127.0.0.1:2"]})).unwrap();
        assert!(wide.check(&manifest).unwrap_err().to_string().contains("net"));
        let env = Grant::from_request(&json!({"env": {"B": "HOME"}})).unwrap();
        assert!(env.check(&manifest).is_err());
        assert!(Grant::from_request(&json!({"env": {"A": "bad-name"}})).is_err());
        assert!(Grant::from_request(&json!({"env": {"A": "/etc/passwd"}})).is_err(), "env takes names only");
        assert!(Grant::from_request(&json!({"file_env": {"T": "/home/u/token"}})).is_ok());
        assert!(Grant::from_request(&json!({"file_env": {"T": "C:\\u\\token"}})).is_ok());
        assert!(Grant::from_request(&json!({"file_env": {"T": "relative/token"}})).is_err());
        let dirs = Grant::from_request(&json!({"dirs": [{"host": "/srv/x", "guest": "/graph/root"}]})).unwrap();
        assert!(dirs.check(&json!({"capabilities": {"dirs": ["/graph/root"]}})).is_ok());
        assert!(dirs.check(&manifest).unwrap_err().to_string().contains("dirs"));
        assert!(Grant::from_request(&json!({"dirs": [{"host": "rel", "guest": "/g"}]})).is_err());
        assert!(Grant::from_request(&json!({"dirs": [{"host": "/srv", "guest": "/g/../etc"}]})).is_err());
    }

    #[test]
    fn names_and_pins() {
        let _dir = TEST_DIR_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        assert!(valid_name("mcp-whatsapp"));
        assert!(!valid_name("../x") && !valid_name("X") && !valid_name(""));
        let dir = std::env::temp_dir().join(format!("wa-components-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::env::set_var("WA_COMPONENTS_DIR", &dir);
        std::fs::write(dir.join("c.wasm"), b"x").unwrap();
        assert!(load("c").err().unwrap().to_string().contains("pin_missing"));
        std::fs::write(dir.join("c.wasm.sha256"), "00").unwrap();
        assert!(load("c").err().unwrap().to_string().contains("hash_mismatch"));
        std::fs::write(dir.join("c.wasm.sha256"), hex(b"x")).unwrap();
        assert_eq!(load("c").unwrap().sha256, hex(b"x"));
        let answer = mcp(&json!({"action": "call", "component": "c", "tool": "t", "schema_hash": "other"}));
        assert_eq!(answer["error"], "mcp_tool_schemas_changed");
        assert_eq!(answer["tool_call_issued"], false);
        std::fs::remove_dir_all(&dir).ok();
    }
}
