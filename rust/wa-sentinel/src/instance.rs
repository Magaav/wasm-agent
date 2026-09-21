//! Named, co-located node instances.
//!
//! One machine can run more than one node: an operator's own master node beside a guest node that
//! belongs to another master. That is the only honest way to test the interesting failures, because
//! they are *between* nodes. Before this module there was one implicit node per machine — one home,
//! one key, one database, one port — and a second `wa serve` would overwrite the first node's
//! registration and pid.
//!
//! An instance is a named bundle of the things that must not be shared:
//!
//!   * a state home (`WASM_AGENT_HOME`): config, `node.key`, `memory.db`, the `env` file
//!   * an install directory (`WA_INSTALL_DIR`): the binary, `ui/`, `serve.pid`
//!   * a node port and a client-bridge port
//!   * a role (`master`/`guest`) and, for a guest, the remote master it is bound to
//!   * a supervisor state directory: its own requests, log, pid and lifecycle record
//!
//! Resources cross the boundary only when the instance says so (`shared_env`). Nothing is inherited
//! implicitly, and a guest is launched with an explicit environment so it cannot pick up the
//! operator's provider keys.
//!
//! Backward compatibility is the default: with no `--instance` (and no `WASM_AGENT_INSTANCE`) the
//! sentinel behaves exactly as it did before, on the ambient home and ports. The registry is only
//! consulted when a name is selected.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const SCHEMA: u64 = 1;

/// The default role when nothing says otherwise. Anything that is not `guest` is a master, matching
/// the node's own `announced_role`; a typo must not quietly demote a node in the middle of work.
fn default_role() -> String {
    "master".to_string()
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Instance {
    pub name: String,
    pub home: String,
    pub install_dir: String,
    pub node_port: u16,
    pub client_port: u16,
    #[serde(default = "default_role")]
    pub role: String,
    /// The remote master a guest is bound to (a node id). Explicit, never inferred from a name.
    #[serde(default)]
    pub master: Option<String>,
    /// Environment variables shared into the child on purpose. Empty means "share nothing".
    #[serde(default)]
    pub shared_env: BTreeMap<String, String>,
    #[serde(default)]
    pub created_at: u64,
}

impl Instance {
    pub fn is_guest(&self) -> bool {
        self.role.eq_ignore_ascii_case("guest")
    }
}

// ---------------------------------------------------------------- registry

/// The operator-level home the registry lives under. Captured once at startup (`main` records it in
/// `WA_INSTANCE_BASE_HOME`) so that selecting an instance — which overwrites `WASM_AGENT_HOME` —
/// cannot move the registry out from under itself.
pub fn base_home() -> PathBuf {
    if let Ok(value) = std::env::var("WA_INSTANCE_BASE_HOME") {
        if !value.is_empty() {
            return PathBuf::from(value);
        }
    }
    crate::home()
}

pub fn registry_path() -> PathBuf {
    if let Ok(value) = std::env::var("WA_INSTANCE_REGISTRY") {
        if !value.is_empty() {
            return PathBuf::from(value);
        }
    }
    base_home().join(".wasm-agent").join("instances.json")
}

pub fn load() -> BTreeMap<String, Instance> {
    let path = registry_path();
    let Ok(text) = std::fs::read_to_string(&path) else {
        return BTreeMap::new();
    };
    let value: Value = match serde_json::from_str(&text) {
        Ok(value) => value,
        Err(error) => {
            // A broken registry must not look like "no instances": say it, and fail closed rather
            // than silently forgetting every instance and letting a start collide.
            crate::audit("instances-bad", &path.display().to_string(), &error.to_string());
            return BTreeMap::new();
        }
    };
    let mut map = BTreeMap::new();
    if let Some(items) = value.get("instances").and_then(Value::as_object) {
        for (name, item) in items {
            match serde_json::from_value::<Instance>(item.clone()) {
                Ok(instance) => {
                    map.insert(name.clone(), instance);
                }
                Err(error) => crate::audit("instance-bad", name, &error.to_string()),
            }
        }
    }
    map
}

pub fn save(map: &BTreeMap<String, Instance>) -> Result<()> {
    let path = registry_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    let mut items = serde_json::Map::new();
    for (name, instance) in map {
        items.insert(name.clone(), serde_json::to_value(instance)?);
    }
    let document = json!({ "schema": SCHEMA, "instances": items });
    wa_operation::atomic_json(&path, &document)
        .with_context(|| format!("write {}", path.display()))?;
    Ok(())
}

pub fn resolve(name: &str) -> Result<Instance> {
    let map = load();
    map.get(name).cloned().with_context(|| {
        format!("unknown instance {name:?}; see `wa-sentinel instance list` (registry {})", registry_path().display())
    })
}

/// Select an instance for the rest of this process: the one place the environment is rewritten.
/// Everything downstream (`home`, `sentinel_dir`, `node_port`, `installed_binary`) already derives
/// from these variables, so this is the whole of instance selection.
pub fn apply_env(instance: &Instance) {
    std::env::set_var("WASM_AGENT_INSTANCE", &instance.name);
    std::env::set_var("WASM_AGENT_HOME", &instance.home);
    std::env::set_var("WASM_AGENT_PORT", instance.node_port.to_string());
    std::env::set_var("WASM_AGENT_CLIENT_PORT", instance.client_port.to_string());
    std::env::set_var("WA_INSTALL_DIR", &instance.install_dir);
    std::env::set_var("WA_UI_DIR", Path::new(&instance.install_dir).join("ui"));
    std::env::set_var("WASM_AGENT_NODE_ROLE", &instance.role);
    match instance.master.as_deref() {
        Some(master) if !master.is_empty() => {
            std::env::set_var("WASM_AGENT_TRUSTED_MASTERS", master)
        }
        _ => std::env::remove_var("WASM_AGENT_TRUSTED_MASTERS"),
    }
}

/// The ambient instance: today's behaviour, unchanged. Used when no `--instance` is selected, so a
/// single-node machine never needs a registry entry.
pub fn default_instance() -> Instance {
    let name = std::env::var("WASM_AGENT_INSTANCE")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "default".to_string());
    Instance {
        name,
        home: crate::home().display().to_string(),
        install_dir: crate::installed_binary()
            .parent()
            .map(|dir| dir.display().to_string())
            .unwrap_or_else(|| ".".to_string()),
        node_port: crate::node_port(),
        client_port: crate::client_port(),
        role: std::env::var("WASM_AGENT_NODE_ROLE").unwrap_or_else(|_| default_role()),
        master: std::env::var("WASM_AGENT_TRUSTED_MASTERS").ok().filter(|v| !v.is_empty()),
        shared_env: BTreeMap::new(),
        created_at: 0,
    }
}

/// The selected instance, or the ambient one. `WA_INSTANCE` names it; a missing name is an error
/// rather than a silent fallback, because acting on the wrong node is the failure this prevents.
pub fn selected() -> Result<Instance> {
    match std::env::var("WASM_AGENT_INSTANCE") {
        Ok(name) if !name.trim().is_empty() => resolve(name.trim()),
        _ => Ok(default_instance()),
    }
}

// ---------------------------------------------------------------- lifecycle record

/// What the sentinel started, so it can prove — before it stops anything — that the pid it is about
/// to kill is still the process it started. A port alone proves nothing: any program can hold it.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Lifecycle {
    pub schema: u64,
    pub pid: u32,
    pub node_id: String,
    pub home: String,
    pub binary: String,
    pub binary_sha256: String,
    pub started_at: u64,
    /// Opaque platform creation marker (Windows FILETIME / Linux starttime ticks). A recycled pid
    /// has a different one; that equality is how "stale pid" is caught.
    pub process_start: u64,
}

pub fn record_path() -> PathBuf {
    crate::sentinel_dir().join("node.json")
}

pub fn write_record(record: &Lifecycle) -> Result<()> {
    wa_operation::atomic_json(&record_path(), &serde_json::to_value(record)?)
        .with_context(|| format!("write {}", record_path().display()))
}

pub fn read_record() -> Option<Lifecycle> {
    let text = std::fs::read_to_string(record_path()).ok()?;
    serde_json::from_str::<Lifecycle>(&text).ok()
}

pub fn clear_record() {
    let _ = std::fs::remove_file(record_path());
}

// ---------------------------------------------------------------- process proof

/// When the process was created, as an opaque platform marker.
pub fn process_start(pid: u32) -> Option<u64> {
    #[cfg(windows)]
    {
        return crate::winproc::process_creation_time(pid);
    }
    #[cfg(not(windows))]
    {
        let text = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        // Field 22 (1-based) is starttime. `comm` can contain spaces and parentheses, so split after
        // the last ')'.
        let rest = text.rsplit_once(')')?.1;
        rest.split_whitespace().nth(19)?.parse().ok()
    }
}

/// The executable image a pid is running.
pub fn process_image(pid: u32) -> Option<PathBuf> {
    #[cfg(windows)]
    {
        return crate::winproc::process_image_path(pid);
    }
    #[cfg(not(windows))]
    {
        std::fs::read_link(format!("/proc/{pid}/exe")).ok()
    }
}

/// Compare two paths as the same file, tolerating case and the Windows verbatim prefix. A path that
/// came from the OS and one we wrote down are the same file or they are not; this is the comparison.
pub fn same_path(left: &Path, right: &Path) -> bool {
    let normal = |path: &Path| {
        let text = path.display().to_string();
        let text = text.strip_prefix(r"\\?\").unwrap_or(&text).to_string();
        text.replace('\\', "/").trim_end_matches('/').to_ascii_lowercase()
    };
    normal(left) == normal(right)
}

// ---------------------------------------------------------------- identity

pub fn node_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub fn sha256_file(path: &Path) -> Result<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).with_context(|| format!("open {}", path.display()))?;
    let mut context = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        context.update(&buffer[..read]);
    }
    Ok(node_hex(context.finish().as_ref()))
}

/// The node id an install/home pair will announce. Computed by asking the binary itself (which
/// generates the key on first use), so the record and the running node agree by construction.
pub fn node_id_for(binary: &Path, home: &Path, clear_env: bool) -> Result<String> {
    let mut command = std::process::Command::new(binary);
    command.arg("node");
    if clear_env {
        command.env_clear();
        for (key, value) in system_env_allowlist() {
            command.env(key, value);
        }
    }
    // Set the home *after* any clear: `env_clear` wipes everything set before it, and a guest
    // identity computed against the operator's ambient home is exactly the wrong-node failure this
    // module exists to prevent (it made the lifecycle record disagree with the running node).
    command.env("WASM_AGENT_HOME", home);
    let output = command
        .output()
        .with_context(|| format!("run {} node", binary.display()))?;
    if !output.status.success() {
        bail!(
            "{} node failed: {}",
            binary.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let value: Value =
        serde_json::from_slice(&output.stdout).context("parse node identity output")?;
    value
        .get("node_id")
        .and_then(Value::as_str)
        .map(str::to_string)
        .context("node identity output had no node_id")
}

// ---------------------------------------------------------------- child environment

/// The system variables a child process needs to start on each platform, and nothing else. This is
/// an allowlist, so an operator's `OPENAI_API_KEY` (or any other secret in the supervisor's
/// environment) cannot reach a guest by inheritance.
pub fn system_env_allowlist() -> Vec<(String, String)> {
    #[cfg(windows)]
    let names = [
        "SystemRoot",
        "SystemDrive",
        "windir",
        "PATH",
        "PATHEXT",
        "TEMP",
        "TMP",
        "COMSPEC",
        "NUMBER_OF_PROCESSORS",
        "OS",
        "PROCESSOR_ARCHITECTURE",
        "PROCESSOR_IDENTIFIER",
        "ProgramData",
        "ProgramFiles",
        "ProgramFiles(x86)",
        "CommonProgramFiles",
        "LOCALAPPDATA",
        "APPDATA",
        "USERPROFILE",
        "USERNAME",
    ];
    #[cfg(not(windows))]
    let names = ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "TERM", "USER"];
    let mut values = Vec::new();
    for name in names {
        if let Ok(value) = std::env::var(name) {
            if !value.is_empty() {
                values.push((name.to_string(), value));
            }
        }
    }
    values
}

/// The explicit environment a guest node is launched with. Every entry is either a system variable
/// the process cannot start without, an instance variable the sentinel owns, or something the
/// operator put in `shared_env` on purpose. Provider keys and other secrets are absent by
/// construction, not by a filter that could miss one.
pub fn guest_env(instance: &Instance) -> Vec<(String, String)> {
    let mut env = system_env_allowlist();
    let mut set = |key: &str, value: String| {
        env.retain(|(existing, _)| existing != key);
        env.push((key.to_string(), value));
    };
    set("WASM_AGENT_HOME", instance.home.clone());
    set("WASM_AGENT_PORT", instance.node_port.to_string());
    set("WASM_AGENT_CLIENT_PORT", instance.client_port.to_string());
    set("WA_INSTALL_DIR", instance.install_dir.clone());
    set("WA_UI_DIR", Path::new(&instance.install_dir).join("ui").display().to_string());
    set("WASM_AGENT_NODE_ROLE", "guest".to_string());
    set("WASM_AGENT_INSTANCE", instance.name.clone());
    if let Some(master) = instance.master.as_deref() {
        if !master.is_empty() {
            set("WASM_AGENT_TRUSTED_MASTERS", master.to_string());
        }
    }
    for (key, value) in &instance.shared_env {
        set(key, value.clone());
    }
    env
}

// ---------------------------------------------------------------- CLI

/// The name a lifecycle subcommand acts on: the positional argument, else the instance already
/// selected with `--instance NAME` (which `apply_env` recorded in `WASM_AGENT_INSTANCE`). This
/// makes `wa-sentinel --instance op instance stop` work, not only `... instance stop op`.
fn name_arg(args: &[String]) -> Result<String> {
    if let Some(name) = args.first().filter(|name| !name.is_empty()) {
        return Ok(name.clone());
    }
    std::env::var("WASM_AGENT_INSTANCE")
        .ok()
        .filter(|name| !name.is_empty())
        .with_context(|| "instance subcommand needs a name, or select one with --instance NAME")
}

fn validate_name(name: &str) -> Result<()> {
    if name.is_empty() {
        bail!("instance needs a name");
    }
    if !name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
    {
        bail!("instance name {name:?} may contain only letters, digits, '-', '_' and '.'");
    }
    Ok(())
}

/// Parse `--key value` and bare `--flag` pairs. Unknown keys are the caller's to validate.
fn flag_map(args: &[String]) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    let mut index = 0;
    while index < args.len() {
        if let Some(key) = args[index].strip_prefix("--") {
            let has_value = args
                .get(index + 1)
                .map(|value| !value.starts_with("--"))
                .unwrap_or(false);
            if has_value {
                map.insert(key.to_string(), args[index + 1].clone());
                index += 2;
            } else {
                map.insert(key.to_string(), "true".to_string());
                index += 1;
            }
        } else {
            index += 1;
        }
    }
    map
}

/// `--share KEY=VALUE`, repeatable. Collected separately because a map would silently keep only the
/// last one, and "which variables are shared" must not depend on argument order.
fn collect_shares(args: &[String]) -> Result<BTreeMap<String, String>> {
    let mut shares = BTreeMap::new();
    let mut index = 0;
    while index < args.len() {
        if args[index] == "--share" {
            let pair = args
                .get(index + 1)
                .with_context(|| "--share needs KEY=VALUE")?;
            let (key, value) = pair
                .split_once('=')
                .with_context(|| format!("--share {pair:?} is not KEY=VALUE"))?;
            if key.is_empty() {
                bail!("--share needs a non-empty KEY");
            }
            shares.insert(key.to_string(), value.to_string());
            index += 2;
        } else {
            index += 1;
        }
    }
    Ok(shares)
}

fn parse_port(value: Option<&String>, label: &str) -> Result<u16> {
    let value = value.with_context(|| format!("instance add needs --{label}"))?;
    value
        .parse::<u16>()
        .with_context(|| format!("--{label} {value:?} is not a port"))
}

fn node_binary(install_dir: &Path) -> PathBuf {
    install_dir.join(if cfg!(windows) { "wa.exe" } else { "wa" })
}

fn copy_dir(source: &Path, target: &Path) -> Result<()> {
    std::fs::create_dir_all(target)?;
    for entry in std::fs::read_dir(source).with_context(|| format!("read {}", source.display()))? {
        let entry = entry?;
        let path = entry.path();
        let destination = target.join(entry.file_name());
        if path.is_dir() {
            copy_dir(&path, &destination)?;
        } else {
            std::fs::copy(&path, &destination)
                .with_context(|| format!("copy {}", path.display()))?;
        }
    }
    Ok(())
}

fn install_binary(binary: &Path, install_dir: &Path, ui: Option<&Path>) -> Result<()> {
    if !binary.is_file() {
        bail!("--binary {} does not exist", binary.display());
    }
    std::fs::create_dir_all(install_dir)?;
    let target = node_binary(install_dir);
    if !same_path(binary, &target) {
        std::fs::copy(binary, &target).with_context(|| format!("copy {}", binary.display()))?;
    }
    if let Some(ui) = ui {
        if !ui.is_dir() {
            bail!("--ui {} is not a directory", ui.display());
        }
        let target_ui = install_dir.join("ui");
        copy_dir(ui, &target_ui)?;
    }
    Ok(())
}

/// Merge instance-owned keys into the home's `env` file. Existing operator-set lines for unrelated
/// keys are left alone; a provider key is never written here by the sentinel.
fn write_env_file(home: &Path, role: &str, master: Option<&str>, name: &str) -> Result<()> {
    let path = home.join(".wasm-agent").join("env");
    let mut lines: Vec<String> = std::fs::read_to_string(&path)
        .unwrap_or_default()
        .lines()
        .map(str::to_string)
        .collect();
    let mut set = |key: &str, value: &str| {
        lines.retain(|line| !line.trim_start().starts_with(&format!("{key}=")));
        lines.push(format!("{key}={value}"));
    };
    set("WASM_AGENT_NODE_ROLE", role);
    set("WASM_AGENT_NODE_NAME", name);
    set("WASM_AGENT_INSTANCE", name);
    if let Some(master) = master {
        set("WASM_AGENT_TRUSTED_MASTERS", master);
    }
    std::fs::write(&path, lines.join("\n") + "\n")
        .with_context(|| format!("write {}", path.display()))?;
    Ok(())
}

fn cli_add(args: &[String]) -> Result<()> {
    let name = args.first().cloned().unwrap_or_default();
    validate_name(&name)?;
    let flags = flag_map(&args[1..]);
    let shares = collect_shares(&args[1..])?;
    let base = base_home();
    let home = flags
        .get("home")
        .map(PathBuf::from)
        .unwrap_or_else(|| base.join(".wasm-agent").join("instances").join(&name));
    let install_dir = flags
        .get("install-dir")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join("install"));
    let role = flags.get("role").cloned().unwrap_or_else(default_role);
    if !role.eq_ignore_ascii_case("master") && !role.eq_ignore_ascii_case("guest") {
        bail!("--role {role:?} must be master or guest");
    }
    let master = flags.get("master").cloned().filter(|value| !value.trim().is_empty());
    if role.eq_ignore_ascii_case("guest") && master.is_none() {
        bail!("a guest instance must name the remote master it is bound to: --master <node-id>");
    }
    let node_port = parse_port(flags.get("port"), "port")?;
    let client_port = parse_port(flags.get("client-port"), "client-port")?;
    if node_port == client_port {
        bail!("--port and --client-port must differ");
    }
    let mut map = load();
    if map.contains_key(&name) {
        bail!("instance {name:?} already exists (remove it first)");
    }
    for (other, instance) in &map {
        if instance.node_port == node_port {
            bail!("node port {node_port} is already used by instance {other:?}");
        }
        if instance.client_port == client_port {
            bail!("client port {client_port} is already used by instance {other:?}");
        }
    }
    std::fs::create_dir_all(home.join(".wasm-agent"))
        .with_context(|| format!("create {}", home.display()))?;
    if let Some(binary) = flags.get("binary") {
        install_binary(Path::new(binary), &install_dir, flags.get("ui").map(Path::new))?;
    }
    std::fs::write(home.join(".wasm-agent").join("node.role"), format!("{role}\n"))?;
    std::fs::write(home.join(".wasm-agent").join("node.name"), format!("{name}\n"))?;
    write_env_file(&home, &role, master.as_deref(), &name)?;

    let binary = node_binary(&install_dir);
    let mut node_id = String::new();
    if binary.is_file() {
        node_id = node_id_for(&binary, &home, role.eq_ignore_ascii_case("guest"))?;
    }
    let instance = Instance {
        name: name.clone(),
        home: home.display().to_string(),
        install_dir: install_dir.display().to_string(),
        node_port,
        client_port,
        role: role.to_ascii_lowercase(),
        master,
        shared_env: shares,
        created_at: crate::now_epoch(),
    };
    map.insert(name.clone(), instance.clone());
    save(&map)?;
    crate::say(&format!(
        "instance {name:?} added: home {} install {} node port {} client port {} role {}{}{}",
        instance.home,
        instance.install_dir,
        instance.node_port,
        instance.client_port,
        instance.role,
        instance
            .master
            .as_deref()
            .map(|m| format!(" master {m}"))
            .unwrap_or_default(),
        if node_id.is_empty() {
            String::new()
        } else {
            format!(" node_id {}", &node_id[..node_id.len().min(12)])
        }
    ));
    crate::audit("instance-add", &name, &instance.role);
    Ok(())
}

fn cli_list() -> Result<()> {
    let map = load();
    if map.is_empty() {
        crate::say(&format!(
            "no instances (registry {}); the default ambient node still works with no registry",
            registry_path().display()
        ));
        return Ok(());
    }
    for instance in map.values() {
        crate::say(&format!(
            "{:<16} role {:<6} node {:<5} client {:<5} home {}",
            instance.name, instance.role, instance.node_port, instance.client_port, instance.home
        ));
    }
    Ok(())
}

fn cli_show(args: &[String]) -> Result<()> {
    let name = name_arg(args)?;
    let instance = resolve(&name)?;
    println!("{}", serde_json::to_string_pretty(&serde_json::to_value(&instance)?)?);
    Ok(())
}

fn cli_remove(args: &[String]) -> Result<()> {
    let name = name_arg(args)?;
    let flags = flag_map(&args[1..]);
    let mut map = load();
    let instance = map
        .get(&name)
        .cloned()
        .with_context(|| format!("unknown instance {name:?}"))?;
    // Do not delete the record of a running node: the lifecycle proof lives in that home, and
    // removing the entry while a process still holds the port is how the next start collides.
    if crate::pid_on_port(instance.node_port).is_some() {
        bail!(
            "instance {name:?} still has a listener on port {}; stop it first",
            instance.node_port
        );
    }
    map.remove(&name);
    save(&map)?;
    if flags.contains_key("purge") {
        let _ = std::fs::remove_dir_all(&instance.home);
        if !same_path(Path::new(&instance.install_dir), Path::new(&instance.home)) {
            let _ = std::fs::remove_dir_all(&instance.install_dir);
        }
    }
    crate::say(&format!("instance {name:?} removed"));
    crate::audit("instance-remove", &name, "removed");
    Ok(())
}

fn cli_start(args: &[String]) -> Result<()> {
    let name = name_arg(args)?;
    let instance = resolve(&name)?;
    apply_env(&instance);
    let detail = crate::verb_restart("instance start")?;
    crate::say(&detail);
    crate::audit("instance-start", &name, "started");
    Ok(())
}

fn cli_stop(args: &[String]) -> Result<()> {
    let name = name_arg(args)?;
    let instance = resolve(&name)?;
    apply_env(&instance);
    crate::stop_node_verified("instance stop", true)?;
    crate::audit("instance-stop", &name, "stopped");
    crate::say(&format!("instance {name:?} stopped"));
    Ok(())
}

fn cli_status(args: &[String]) -> Result<()> {
    let name = name_arg(args)?;
    let instance = resolve(&name)?;
    apply_env(&instance);
    let health = crate::health();
    crate::say(&format!(
        "instance:  {} role {} home {}",
        instance.name, instance.role, instance.home
    ));
    crate::say(&format!(
        "node:      port {} {}",
        instance.node_port,
        match &health {
            Some(value) => format!("up ok={}", value.get("ok").and_then(Value::as_bool).unwrap_or(false)),
            None => "not answering".into(),
        }
    ));
    match read_record() {
        Some(record) => {
            let live = crate::pid_on_port(instance.node_port) == Some(record.pid);
            crate::say(&format!(
                "record:    pid {} node_id {} live {}",
                record.pid,
                &record.node_id[..record.node_id.len().min(12)],
                live
            ));
        }
        None => crate::say("record:    none (node not started by this sentinel)"),
    }
    Ok(())
}

/// `wa-sentinel instance ...`. Registry operations do not require selecting an instance; lifecycle
/// operations (`start`/`stop`/`status`) select the named one themselves.
pub fn cli(args: &[String]) -> Result<()> {
    let sub = args.first().map(String::as_str).unwrap_or("list");
    let rest = if args.len() > 1 { &args[1..] } else { &[] };
    match sub {
        "add" => cli_add(rest),
        "list" | "ls" => cli_list(),
        "show" => cli_show(rest),
        "remove" | "rm" => cli_remove(rest),
        "start" => cli_start(rest),
        "stop" => cli_stop(rest),
        "status" => cli_status(rest),
        other => bail!("unknown instance subcommand {other:?}; use add|list|show|remove|start|stop|status"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// These tests set process-wide environment variables, and the test harness runs them in
    /// parallel threads of one process. Serialise them so one test's registry cannot be read or
    /// cleared by another's setup - a race that made the port-collision test pass or fail by timing.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn env_guard() -> std::sync::MutexGuard<'static, ()> {
        ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn sample(name: &str, node_port: u16, client_port: u16, role: &str) -> Instance {
        Instance {
            name: name.into(),
            home: format!("/tmp/{name}"),
            install_dir: format!("/tmp/{name}/install"),
            node_port,
            client_port,
            role: role.into(),
            master: if role == "guest" { Some("master-node-id".into()) } else { None },
            shared_env: BTreeMap::new(),
            created_at: 0,
        }
    }

    #[test]
    fn a_guest_must_name_its_master() {
        let _guard = env_guard();
        let dir = std::env::temp_dir().join(format!("wa-instance-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::env::set_var("WA_INSTANCE_BASE_HOME", &dir);
        std::env::set_var("WA_INSTANCE_REGISTRY", dir.join("instances.json"));
        let error = cli_add(&[
            "g".into(),
            "--port".into(),
            "18999".into(),
            "--client-port".into(),
            "19000".into(),
            "--role".into(),
            "guest".into(),
        ])
        .unwrap_err()
        .to_string();
        assert!(error.contains("--master"), "{error}");
        std::env::remove_var("WA_INSTANCE_REGISTRY");
        std::env::remove_var("WA_INSTANCE_BASE_HOME");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_second_instance_cannot_claim_the_same_ports() {
        let _guard = env_guard();
        let dir = std::env::temp_dir().join(format!("wa-instance-ports-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::env::set_var("WA_INSTANCE_BASE_HOME", &dir);
        std::env::set_var("WA_INSTANCE_REGISTRY", dir.join("instances.json"));
        let map = BTreeMap::from([("a".to_string(), sample("a", 18991, 18992, "master"))]);
        save(&map).expect("save");
        let error = cli_add(&[
            "b".into(),
            "--port".into(),
            "18991".into(),
            "--client-port".into(),
            "18993".into(),
        ])
        .unwrap_err()
        .to_string();
        assert!(error.contains("already used"), "{error}");
        std::env::remove_var("WA_INSTANCE_REGISTRY");
        std::env::remove_var("WA_INSTANCE_BASE_HOME");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn guest_env_shares_nothing_but_the_allowlist_and_explicit_values() {
        let _guard = env_guard();
        std::env::set_var("WA_TEST_SECRET_API_KEY", "sk-do-not-leak");
        let instance = sample("guest", 18994, 18995, "guest");
        let env = guest_env(&instance);
        assert!(
            !env.iter().any(|(key, _)| key == "WA_TEST_SECRET_API_KEY"),
            "a secret in the supervisor environment must not reach the guest"
        );
        assert!(env.iter().any(|(key, value)| key == "WASM_AGENT_NODE_ROLE" && value == "guest"));
        assert!(env.iter().any(|(key, value)| key == "WASM_AGENT_TRUSTED_MASTERS" && value == "master-node-id"));
        std::env::remove_var("WA_TEST_SECRET_API_KEY");
    }

    #[test]
    fn shared_values_cross_only_when_declared() {
        let _guard = env_guard();
        let mut instance = sample("guest", 18996, 18997, "guest");
        instance
            .shared_env
            .insert("WASM_AGENT_RENDEZVOUS".into(), "https://example.invalid".into());
        let env = guest_env(&instance);
        assert!(env.iter().any(|(key, value)| key == "WASM_AGENT_RENDEZVOUS" && value == "https://example.invalid"));
    }
}
