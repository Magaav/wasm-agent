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
//! Resources cross the boundary only when the instance says so (`shared_env`), and the keys that
//! decide *where* a node reads and writes and *what authority* it has are never shareable. Nothing
//! is inherited implicitly, and a named guest is launched with an explicit environment so it cannot
//! pick up the operator's provider keys.
//!
//! **This is application-level home isolation, not an OS sandbox.** Two instances get different
//! config, keys, databases and ports; they run as the same operating-system account, so a guest
//! process can still read anything that account can read. It is not a container and does not claim
//! to be one.
//!
//! Backward compatibility is the default: with no `--instance` (and no `WASM_AGENT_INSTANCE`) the
//! sentinel behaves exactly as it did before, on the ambient home and ports. The registry is only
//! consulted when a name is selected.
//!
//! The registry is **fail-closed**. A missing file is an empty registry; a file that cannot be read
//! or parsed, or that carries an invalid schema/entry, is an error. It is never silently treated as
//! empty, because the next `add` would then overwrite it and lose every instance.

use anyhow::{bail, Context, Result};
use ring::signature::KeyPair;
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

/// The marker written into a home the sentinel created. `remove --purge` requires it, so a purge can
/// never recursively delete a directory the operator pointed at by hand.
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Owned {
    schema: u64,
    name: String,
    created_at: u64,
}

// ---------------------------------------------------------------- protected environment

/// Keys that decide where a node reads and writes, or what authority it has. A `shared_env` entry
/// must never be able to set one: `guest_env` applies shares, then these, but rejecting them at
/// `add` is what makes the boundary a rule rather than a convention. Case-insensitive, because
/// Windows environment variables are.
const PROTECTED_ENV_KEYS: &[&str] = &[
    "HOME",
    "USERPROFILE",
    "HOMEDRIVE",
    "HOMEPATH",
    "PATH",
    "PATHEXT",
    "COMSPEC",
    "WASM_AGENT_HOME",
    "WASM_AGENT_DB",
    "WASM_AGENT_NODE_KEY",
    "WASM_AGENT_NODE_ROLE",
    "WASM_AGENT_MANAGED",
    "WASM_AGENT_INSTANCE",
    "WASM_AGENT_PORT",
    "WASM_AGENT_CLIENT_PORT",
    "WASM_AGENT_TRUSTED_MASTERS",
    "WASM_AGENT_LUA_ROOT",
    "WASM_AGENT_PLUGINS",
    "WASM_AGENT_UI",
    "WA_INSTALL_DIR",
    "WA_UI_DIR",
    "WA_SCRIPT",
];

pub fn is_protected_env_key(key: &str) -> bool {
    let upper = key.trim().to_ascii_uppercase();
    PROTECTED_ENV_KEYS.contains(&upper.as_str())
}

/// A shareable environment key: non-empty, no `=`, no newline/NUL (an environment block is
/// NUL-delimited and line-oriented), and not a protected authority/path key.
fn validate_env_key(key: &str) -> Result<()> {
    if key.is_empty() {
        bail!("environment key is empty");
    }
    if key.contains('=') {
        bail!("environment key {key:?} contains '='");
    }
    if key.contains('\n') || key.contains('\r') || key.contains('\0') {
        bail!("environment key {key:?} contains a newline or NUL");
    }
    if is_protected_env_key(key) {
        bail!(
            "environment key {key:?} is protected (home/role/ports/install/trusted-masters/path authority) and cannot be shared"
        );
    }
    Ok(())
}

// ---------------------------------------------------------------- paths

fn strip_verbatim(text: &str) -> &str {
    text.strip_prefix(r"\\?\").unwrap_or(text)
}

/// Canonicalize as far as the filesystem allows. The target may not exist yet, so the nearest
/// existing ancestor is canonicalized (which resolves symlinks and case aliases) and the remaining
/// components are re-attached.
pub fn canonical_loose(path: &Path) -> PathBuf {
    if let Ok(canonical) = std::fs::canonicalize(path) {
        return PathBuf::from(strip_verbatim(&canonical.display().to_string()));
    }
    let mut tail: Vec<std::ffi::OsString> = Vec::new();
    let mut current = path.to_path_buf();
    loop {
        if let Some(name) = current.file_name() {
            tail.push(name.to_os_string());
        }
        match current.parent() {
            Some(parent) if !parent.as_os_str().is_empty() => {
                if let Ok(canonical) = std::fs::canonicalize(parent) {
                    let mut out = PathBuf::from(strip_verbatim(&canonical.display().to_string()));
                    for name in tail.iter().rev() {
                        out.push(name);
                    }
                    return out;
                }
                current = parent.to_path_buf();
            }
            _ => break,
        }
    }
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().unwrap_or_default().join(path)
    };
    PathBuf::from(absolute.display().to_string().replace('\\', "/"))
}

/// A lexical normalization used for comparing two paths that name the same file: strip the Windows
/// verbatim prefix, unify separators, drop a trailing slash, and case-fold on Windows. It does not
/// touch the filesystem, so it is safe to call on a path that does not exist yet.
fn lexical(path: &Path) -> String {
    let text = path.display().to_string();
    let text = strip_verbatim(&text).replace('\\', "/");
    let text = text.trim_end_matches('/').to_string();
    if cfg!(windows) {
        text.to_ascii_lowercase()
    } else {
        text
    }
}

/// True when the two paths are the same file (case- and separator-insensitive on Windows).
pub fn same_path(left: &Path, right: &Path) -> bool {
    lexical(left) == lexical(right)
}

/// The canonicalizing normalization used for overlap and alias checks, where a symlink or a case
/// alias must be resolved against the filesystem.
fn norm_path_string(path: &Path) -> String {
    lexical(&canonical_loose(path))
}

/// True when `a` is `b`, or a directory that contains `b`. Used both ways for overlap.
fn is_self_or_ancestor_of(a: &Path, b: &Path) -> bool {
    let a = norm_path_string(a);
    let b = norm_path_string(b);
    a == b || b.starts_with(&format!("{a}/"))
}

/// True when either path is the same as, or contains, the other. Two instances may not overlap.
pub fn paths_overlap(a: &Path, b: &Path) -> bool {
    is_self_or_ancestor_of(a, b) || is_self_or_ancestor_of(b, a)
}

fn is_symlink(path: &Path) -> bool {
    std::fs::symlink_metadata(path)
        .map(|meta| meta.file_type().is_symlink())
        .unwrap_or(false)
}

fn dir_nonempty(path: &Path) -> bool {
    std::fs::read_dir(path)
        .map(|mut entries| entries.next().is_some())
        .unwrap_or(false)
}

pub fn operator_home() -> PathBuf {
    base_home()
}

pub fn operator_config() -> PathBuf {
    base_home().join(".wasm-agent")
}

pub fn operator_install() -> PathBuf {
    // Pinned at startup, before `--instance` can overwrite `WA_INSTALL_DIR`. Without the pin, the
    // selected instance's own install reads as "the operator install", and every instance looks like
    // it overlaps the operator.
    if let Ok(value) = std::env::var("WA_INSTANCE_OPERATOR_INSTALL") {
        if !value.is_empty() {
            return PathBuf::from(value);
        }
    }
    crate::installed_binary()
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."))
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

/// Load the registry. A missing file is an empty registry; **anything else is an error**. A parse
/// error must not read as "no instances", because the next `add` would then overwrite the file and
/// silently drop every instance it could not parse.
pub fn load() -> Result<BTreeMap<String, Instance>> {
    load_from(&registry_path())
}

pub fn load_from(path: &Path) -> Result<BTreeMap<String, Instance>> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(BTreeMap::new()),
        Err(error) => {
            return Err(error).with_context(|| format!("read instance registry {}", path.display()))
        }
    };
    let value: Value = serde_json::from_str(&text)
        .with_context(|| format!("parse instance registry {} (refusing to treat it as empty)", path.display()))?;
    let schema = value
        .get("schema")
        .and_then(Value::as_u64)
        .with_context(|| format!("instance registry {} has no integer schema", path.display()))?;
    if schema != SCHEMA {
        bail!(
            "instance registry {} has schema {schema}, expected {SCHEMA}",
            path.display()
        );
    }
    let items = value
        .get("instances")
        .and_then(Value::as_object)
        .with_context(|| format!("instance registry {} has no instances object", path.display()))?;
    let mut map = BTreeMap::new();
    for (name, item) in items {
        let instance: Instance = serde_json::from_value(item.clone())
            .with_context(|| format!("instance {name:?} in {} is invalid", path.display()))?;
        validate_instance(name, &instance, &map)?;
        map.insert(name.clone(), instance);
    }
    Ok(map)
}

pub fn save(map: &BTreeMap<String, Instance>) -> Result<()> {
    // Validate before writing: a save must never be the thing that introduces a registry the next
    // load refuses.
    for (name, instance) in map {
        validate_instance(name, instance, map)?;
    }
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

/// Validate one entry against the schema and against the others. Used on load *and* before save, so
/// a hand-edited registry cannot become a valid one by being read.
fn validate_instance(name: &str, instance: &Instance, others: &BTreeMap<String, Instance>) -> Result<()> {
    if name.is_empty() {
        bail!("instance registry has an entry with an empty name");
    }
    if instance.name != name {
        bail!("instance {name:?} carries name {:?}; the key and the name must agree", instance.name);
    }
    let role = instance.role.to_ascii_lowercase();
    if role != "master" && role != "guest" {
        bail!("instance {name:?} role {:?} must be master or guest", instance.role);
    }
    if instance.node_port == 0 || instance.client_port == 0 {
        bail!("instance {name:?} has a zero port");
    }
    if instance.node_port == instance.client_port {
        bail!("instance {name:?} node and client ports are equal");
    }
    match (instance.master.as_deref(), role.as_str()) {
        (Some(master), "guest") if is_node_id(master) => {}
        (None, "master") => {}
        (Some(_), "master") => {
            bail!("instance {name:?} is a master and must not bind a remote master")
        }
        (_, "guest") => bail!(
            "instance {name:?} is a guest and must name a valid 32-hex node id as its remote master"
        ),
        _ => {}
    }
    for key in instance.shared_env.keys() {
        validate_env_key(key).with_context(|| format!("instance {name:?} shared_env"))?;
    }
    if instance.home.trim().is_empty() {
        bail!("instance {name:?} has an empty home");
    }
    if instance.install_dir.trim().is_empty() {
        bail!("instance {name:?} has an empty install_dir");
    }
    // A named home/install must not be, or contain, the operator's own home/config/install.
    for (label, operator) in [
        ("operator home", operator_home()),
        ("operator config", operator_config()),
        ("operator install", operator_install()),
    ] {
        if is_self_or_ancestor_of(Path::new(&instance.home), &operator) {
            bail!(
                "instance {name:?} home {} would own the {label} {}",
                instance.home,
                operator.display()
            );
        }
        if is_self_or_ancestor_of(Path::new(&instance.install_dir), &operator) {
            bail!(
                "instance {name:?} install {} would own the {label} {}",
                instance.install_dir,
                operator.display()
            );
        }
    }
    for (other_name, other) in others {
        if other_name == name {
            continue;
        }
        for (label, port) in [("node", instance.node_port), ("client", instance.client_port)] {
            if port == other.node_port || port == other.client_port {
                bail!(
                    "instance {name:?} {label} port {port} collides with instance {other_name:?}"
                );
            }
        }
        if paths_overlap(Path::new(&instance.home), Path::new(&other.home))
            || paths_overlap(Path::new(&instance.home), Path::new(&other.install_dir))
            || paths_overlap(Path::new(&instance.install_dir), Path::new(&other.home))
            || paths_overlap(Path::new(&instance.install_dir), Path::new(&other.install_dir))
        {
            bail!("instance {name:?} home/install overlaps instance {other_name:?}");
        }
    }
    Ok(())
}

fn is_node_id(value: &str) -> bool {
    value.len() == 32
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub fn resolve(name: &str) -> Result<Instance> {
    let map = load()?;
    map.get(name).cloned().with_context(|| {
        format!(
            "unknown instance {name:?}; see `wa-sentinel instance list` (registry {})",
            registry_path().display()
        )
    })
}

/// Select an instance for the rest of this process: the one place the environment is rewritten.
pub fn apply_env(instance: &Instance) {
    std::env::set_var("WASM_AGENT_INSTANCE", &instance.name);
    std::env::set_var("WASM_AGENT_HOME", &instance.home);
    std::env::set_var("WASM_AGENT_PORT", instance.node_port.to_string());
    std::env::set_var("WASM_AGENT_CLIENT_PORT", instance.client_port.to_string());
    std::env::set_var("WA_INSTALL_DIR", &instance.install_dir);
    std::env::set_var("WA_UI_DIR", Path::new(&instance.install_dir).join("ui"));
    std::env::set_var("WASM_AGENT_NODE_ROLE", &instance.role);
    match instance.master.as_deref() {
        Some(master) if !master.is_empty() => std::env::set_var("WASM_AGENT_TRUSTED_MASTERS", master),
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
        master: std::env::var("WASM_AGENT_TRUSTED_MASTERS")
            .ok()
            .filter(|value| !value.is_empty()),
        shared_env: BTreeMap::new(),
        created_at: 0,
    }
}

/// The selected instance, or the ambient one. A named instance that cannot be loaded is an error
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
    validate_record(record)?;
    wa_operation::atomic_json(&record_path(), &serde_json::to_value(record)?)
        .with_context(|| format!("write {}", record_path().display()))
}

/// `Ok(None)` means there is no record. A record that exists but cannot be read, parsed or validated
/// is an **error**: falling back to the weaker `serve.pid` path on a corrupt record is how a
/// half-written file turns into a stop of the wrong process.
pub fn read_record() -> Result<Option<Lifecycle>> {
    let path = record_path();
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error).with_context(|| format!("read {}", path.display())),
    };
    let record: Lifecycle = serde_json::from_str(&text)
        .with_context(|| format!("corrupt lifecycle record {} (refusing to fall back to serve.pid)", path.display()))?;
    validate_record(&record)?;
    Ok(Some(record))
}

fn validate_record(record: &Lifecycle) -> Result<()> {
    if record.schema != SCHEMA {
        bail!("lifecycle record schema {} is not {SCHEMA}", record.schema);
    }
    if record.pid == 0 {
        bail!("lifecycle record has no pid");
    }
    if record.node_id.is_empty() {
        bail!("lifecycle record has no node_id");
    }
    if record.home.is_empty() {
        bail!("lifecycle record has no home");
    }
    if record.binary.is_empty() {
        bail!("lifecycle record has no binary");
    }
    if record.process_start == 0 {
        bail!("lifecycle record has no process creation marker");
    }
    Ok(())
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

// ---------------------------------------------------------------- identity

pub fn node_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    let text = text.trim();
    if !text.is_ascii() || text.len() % 2 != 0 {
        return None;
    }
    (0..text.len() / 2)
        .map(|index| u8::from_str_radix(&text[index * 2..index * 2 + 2], 16).ok())
        .collect()
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

/// The node id a home's key will announce, derived without starting the node. This is the positive
/// identity a legacy adoption needs: the running node's `/sync/head` must equal it.
pub fn expected_node_id_from_home(home: &Path) -> Result<String> {
    let path = home.join(".wasm-agent").join("node.key");
    let text = std::fs::read_to_string(&path)
        .with_context(|| format!("read node key {}", path.display()))?;
    let pkcs8 = unhex(&text).with_context(|| format!("node key {} is not hex", path.display()))?;
    let key = ring::signature::Ed25519KeyPair::from_pkcs8(&pkcs8)
        .map_err(|error| anyhow::anyhow!("node key {} is not a valid ed25519 key: {error}", path.display()))?;
    let digest = ring::digest::digest(&ring::digest::SHA256, key.public_key().as_ref());
    Ok(node_hex(digest.as_ref())[..32].to_string())
}

/// The node id an install/home pair will announce, by asking the binary itself (which generates the
/// key on first use), so a fresh instance's record and its running node agree by construction.
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
    // module exists to prevent.
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
/// the process cannot start without, a non-protected `shared_env` entry the operator declared, or an
/// instance variable the sentinel owns. The instance variables are applied **last**, so even a share
/// that somehow reached the map cannot override the boundary.
pub fn guest_env(instance: &Instance) -> Vec<(String, String)> {
    let mut env = system_env_allowlist();
    let mut set = |key: &str, value: String| {
        env.retain(|(existing, _)| !existing.eq_ignore_ascii_case(key));
        env.push((key.to_string(), value));
    };
    for (key, value) in &instance.shared_env {
        if !is_protected_env_key(key) {
            set(key, value.clone());
        }
    }
    set("WASM_AGENT_HOME", instance.home.clone());
    set("WASM_AGENT_PORT", instance.node_port.to_string());
    set("WASM_AGENT_CLIENT_PORT", instance.client_port.to_string());
    set("WA_INSTALL_DIR", instance.install_dir.clone());
    set(
        "WA_UI_DIR",
        Path::new(&instance.install_dir).join("ui").display().to_string(),
    );
    set("WASM_AGENT_NODE_ROLE", "guest".to_string());
    set("WASM_AGENT_INSTANCE", instance.name.clone());
    if let Some(master) = instance.master.as_deref() {
        if !master.is_empty() {
            set("WASM_AGENT_TRUSTED_MASTERS", master.to_string());
        }
    }
    env
}

// ---------------------------------------------------------------- CLI helpers

/// The name a lifecycle subcommand acts on: the positional argument, else the instance already
/// selected with `--instance NAME` (which `apply_env` recorded in `WASM_AGENT_INSTANCE`).
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

/// `--share KEY=VALUE`, repeatable. A protected or malformed key is refused here, so it can never
/// reach the registry.
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
            validate_env_key(key)?;
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
        copy_dir(ui, &install_dir.join("ui"))?;
    }
    Ok(())
}

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

fn owned_marker_path(home: &Path) -> PathBuf {
    home.join(".wasm-agent").join("instance.json")
}

fn write_owned_marker(home: &Path, name: &str) -> Result<()> {
    let marker = Owned {
        schema: SCHEMA,
        name: name.to_string(),
        created_at: crate::now_epoch(),
    };
    let path = owned_marker_path(home);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    wa_operation::atomic_json(&path, &serde_json::to_value(&marker)?)
        .with_context(|| format!("write {}", path.display()))
}

fn read_owned_marker(home: &Path) -> Result<Owned> {
    let path = owned_marker_path(home);
    let text = std::fs::read_to_string(&path)
        .with_context(|| format!("read owned marker {}", path.display()))?;
    let marker: Owned = serde_json::from_str(&text)
        .with_context(|| format!("parse owned marker {}", path.display()))?;
    if marker.schema != SCHEMA {
        bail!("owned marker {} has schema {}", path.display(), marker.schema);
    }
    Ok(marker)
}

/// Path safety for `add`: no symlinks, no operator home/config/install, no foreign non-empty home,
/// and no overwrite of an existing `env`/`config`. Cross-instance overlap is checked by
/// `validate_instance`.
fn validate_add_paths(name: &str, home: &Path, install: &Path) -> Result<()> {
    for (label, path) in [("home", home), ("install", install)] {
        if is_symlink(path) {
            bail!("instance {name:?} {label} {} is a symlink; refusing to use it", path.display());
        }
        for (operator_label, operator) in [
            ("operator home", operator_home()),
            ("operator config", operator_config()),
            ("operator install", operator_install()),
        ] {
            if is_self_or_ancestor_of(path, &operator) {
                bail!(
                    "instance {name:?} {label} {} would own the {operator_label} {}",
                    path.display(),
                    operator.display()
                );
            }
        }
    }
    // The install may live inside the home (the default), but the home may not live inside the
    // install: the config would then sit under the binary directory.
    if !same_path(home, install) && is_self_or_ancestor_of(install, home) {
        bail!(
            "instance {name:?} install {} contains its home {}",
            install.display(),
            home.display()
        );
    }
    if home.exists() {
        match read_owned_marker(home) {
            Ok(marker) if marker.name == name => {
                bail!("instance {name:?} already has an owned home at {}", home.display())
            }
            Ok(marker) => bail!(
                "instance {name:?} home {} belongs to instance {:?}",
                home.display(),
                marker.name
            ),
            Err(_) => {
                if dir_nonempty(home) {
                    bail!(
                        "instance {name:?} home {} already exists and is not an owned instance home; refusing to overwrite it",
                        home.display()
                    );
                }
            }
        }
    }
    for file in ["env", "config"] {
        let path = home.join(".wasm-agent").join(file);
        if path.exists() && std::fs::metadata(&path).map(|meta| meta.len() > 0).unwrap_or(false) {
            bail!(
                "instance {name:?} would overwrite the existing {}; refusing",
                path.display()
            );
        }
    }
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
    let role = flags.get("role").cloned().unwrap_or_else(default_role).to_ascii_lowercase();
    if role != "master" && role != "guest" {
        bail!("--role {role:?} must be master or guest");
    }
    let master = flags.get("master").cloned().filter(|value| !value.trim().is_empty());
    if role == "guest" {
        let master = master
            .as_deref()
            .with_context(|| "a guest instance must name the remote master it is bound to: --master <node-id>")?;
        if !is_node_id(master) {
            bail!("--master {master:?} is not a 32-hex node id (a name or alias is not an identity)");
        }
    }
    if role == "master" && master.is_some() {
        bail!("a master instance must not bind a remote master");
    }
    let node_port = parse_port(flags.get("port"), "port")?;
    let client_port = parse_port(flags.get("client-port"), "client-port")?;
    if node_port == client_port {
        bail!("--port and --client-port must differ");
    }
    let mut map = load()?;
    if map.contains_key(&name) {
        bail!("instance {name:?} already exists (remove it first)");
    }
    let instance = Instance {
        name: name.clone(),
        home: home.display().to_string(),
        install_dir: install_dir.display().to_string(),
        node_port,
        client_port,
        role,
        master,
        shared_env: shares,
        created_at: crate::now_epoch(),
    };
    // Schema/role/port/cross-instance/overlap checks, then the filesystem safety checks.
    validate_instance(&name, &instance, &map)?;
    validate_add_paths(&name, &home, &install_dir)?;

    std::fs::create_dir_all(home.join(".wasm-agent"))
        .with_context(|| format!("create {}", home.display()))?;
    if let Some(binary) = flags.get("binary") {
        install_binary(Path::new(binary), &install_dir, flags.get("ui").map(Path::new))?;
    }
    std::fs::write(home.join(".wasm-agent").join("node.role"), format!("{}\n", instance.role))?;
    std::fs::write(home.join(".wasm-agent").join("node.name"), format!("{name}\n"))?;
    write_env_file(&home, &instance.role, instance.master.as_deref(), &name)?;
    write_owned_marker(&home, &name)?;

    let binary = node_binary(&install_dir);
    let mut node_id = String::new();
    if binary.is_file() {
        node_id = node_id_for(&binary, &home, instance.is_guest())?;
    }
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
    let map = load()?;
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

/// Reject a purge target that is the operator's own home/config/install, a filesystem root, or a
/// directory the sentinel did not create. `--purge` recursively deletes, so this is the guard.
fn validate_purge_target(name: &str, home: &Path) -> Result<()> {
    if home.as_os_str().is_empty() {
        bail!("instance {name:?} has no home to purge");
    }
    if is_symlink(home) {
        bail!("instance {name:?} home {} is a symlink; refusing to purge", home.display());
    }
    let normalized = norm_path_string(home);
    if normalized.is_empty() || normalized == "/" || normalized.ends_with(":") {
        bail!("instance {name:?} home {} is a filesystem root; refusing to purge", home.display());
    }
    for (label, operator) in [
        ("operator home", operator_home()),
        ("operator config", operator_config()),
        ("operator install", operator_install()),
    ] {
        // Only a home that *is* or *contains* the operator path is refused. A named instance's
        // default home is nested under the operator config, and purging it must stay allowed.
        if is_self_or_ancestor_of(home, &operator) {
            bail!(
                "instance {name:?} home {} would delete the {label} {}; refusing to purge",
                home.display(),
                operator.display()
            );
        }
    }
    let marker = read_owned_marker(home)
        .with_context(|| format!("instance {name:?} home {} has no owned marker; refusing to purge", home.display()))?;
    if marker.name != name {
        bail!(
            "instance {name:?} home {} is owned by {:?}; refusing to purge",
            home.display(),
            marker.name
        );
    }
    Ok(())
}

fn cli_remove(args: &[String]) -> Result<()> {
    let name = name_arg(args)?;
    let flags = flag_map(&args[1..]);
    let mut map = load()?;
    let instance = map
        .get(&name)
        .cloned()
        .with_context(|| format!("unknown instance {name:?}"))?;
    if crate::pid_on_port(instance.node_port).is_some() {
        bail!(
            "instance {name:?} still has a listener on port {}; stop it first",
            instance.node_port
        );
    }
    if !flags.contains_key("purge") {
        map.remove(&name);
        save(&map)?;
        crate::say(&format!("instance {name:?} removed (home left in place)"));
        crate::audit("instance-remove", &name, "removed");
        return Ok(());
    }
    let home = PathBuf::from(&instance.home);
    let install = PathBuf::from(&instance.install_dir);
    validate_purge_target(&name, &home)?;
    // Purge the data first, and only then forget the instance. If a delete fails, the registry entry
    // stays so the failure is visible and the state is recoverable, rather than a silent success.
    if let Err(error) = std::fs::remove_dir_all(&home) {
        bail!(
            "instance {name:?} purge failed for {}: {error}; the registry entry was kept",
            home.display()
        );
    }
    if !same_path(&install, &home) && !is_self_or_ancestor_of(&home, &install) {
        // An install outside the home must also be owned by this instance before it is deleted.
        match read_owned_marker(&install) {
            Ok(marker) if marker.name == name => {
                if let Err(error) = std::fs::remove_dir_all(&install) {
                    bail!(
                        "instance {name:?} home purged but install {} failed: {error}; the registry entry was kept",
                        install.display()
                    );
                }
            }
            _ => crate::say(&format!(
                "instance {name:?} install {} is outside the home and not owned by it; left in place",
                install.display()
            )),
        }
    }
    map.remove(&name);
    save(&map)?;
    crate::say(&format!("instance {name:?} purged"));
    crate::audit("instance-remove", &name, "purged");
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
        Ok(Some(record)) => {
            let live = crate::pid_on_port(instance.node_port) == Some(record.pid);
            crate::say(&format!(
                "record:    pid {} node_id {} live {}",
                record.pid,
                &record.node_id[..record.node_id.len().min(12)],
                live
            ));
        }
        Ok(None) => crate::say("record:    none (node not started by this sentinel)"),
        Err(error) => crate::say(&format!("record:    unreadable: {error}")),
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
    /// cleared by another's setup.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn env_guard() -> std::sync::MutexGuard<'static, ()> {
        ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    struct Scratch {
        dir: PathBuf,
    }
    impl Scratch {
        fn new(label: &str) -> Scratch {
            let dir = std::env::temp_dir().join(format!("wa-instance-{label}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).expect("scratch");
            std::env::set_var("WA_INSTANCE_BASE_HOME", &dir);
            std::env::set_var("WA_INSTANCE_REGISTRY", dir.join("instances.json"));
            Scratch { dir }
        }
        fn registry(&self) -> PathBuf {
            self.dir.join("instances.json")
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            std::env::remove_var("WA_INSTANCE_REGISTRY");
            std::env::remove_var("WA_INSTANCE_BASE_HOME");
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    fn sample(name: &str, node_port: u16, client_port: u16, role: &str) -> Instance {
        Instance {
            name: name.into(),
            home: format!("/tmp/{name}"),
            install_dir: format!("/tmp/{name}/install"),
            node_port,
            client_port,
            role: role.into(),
            master: if role == "guest" {
                Some("0123456789abcdef0123456789abcdef".into())
            } else {
                None
            },
            shared_env: BTreeMap::new(),
            created_at: 0,
        }
    }

    #[test]
    fn a_guest_must_name_a_real_master_node_id() {
        let _guard = env_guard();
        let _scratch = Scratch::new("guest-master");
        let missing = cli_add(&[
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
        assert!(missing.contains("--master"), "{missing}");
        let alias = cli_add(&[
            "g".into(),
            "--port".into(),
            "18999".into(),
            "--client-port".into(),
            "19000".into(),
            "--role".into(),
            "guest".into(),
            "--master".into(),
            "some-friendly-name".into(),
        ])
        .unwrap_err()
        .to_string();
        assert!(alias.contains("32-hex"), "{alias}");
    }

    #[test]
    fn a_second_instance_cannot_claim_any_port_in_use() {
        let _guard = env_guard();
        let _scratch = Scratch::new("ports");
        let map = BTreeMap::from([("a".to_string(), sample("a", 18991, 18992, "master"))]);
        save(&map).expect("save");
        // node collides with the existing node
        assert!(cli_add(&["b".into(), "--port".into(), "18991".into(), "--client-port".into(), "18993".into()]).is_err());
        // node collides with the existing *client* port (the cross-role case the first version missed)
        assert!(cli_add(&["b".into(), "--port".into(), "18992".into(), "--client-port".into(), "18993".into()]).is_err());
        // client collides with the existing node port
        assert!(cli_add(&["b".into(), "--port".into(), "18993".into(), "--client-port".into(), "18991".into()]).is_err());
        // distinct ports are accepted
        cli_add(&["b".into(), "--port".into(), "18993".into(), "--client-port".into(), "18994".into()]).expect("distinct ports");
    }

    #[test]
    fn protected_and_malformed_shares_are_refused() {
        let _guard = env_guard();
        let _scratch = Scratch::new("shares");
        for key in [
            "WASM_AGENT_HOME",
            "WASM_AGENT_NODE_ROLE",
            "WASM_AGENT_PORT",
            "WA_INSTALL_DIR",
            "WASM_AGENT_TRUSTED_MASTERS",
            "HOME",
            "Path",
        ] {
            let error = collect_shares(&["--share".into(), format!("{key}=x")])
                .unwrap_err()
                .to_string();
            assert!(error.contains("protected"), "{key}: {error}");
        }
        assert!(collect_shares(&["--share".into(), "BAD\nKEY=x".into()]).is_err());
        assert!(collect_shares(&["--share".into(), "WASM_AGENT_RENDEZVOUS=https://example.invalid".into()]).is_ok());
    }

    #[test]
    fn a_named_home_cannot_be_the_operator_home_or_overlap_another() {
        let _guard = env_guard();
        let _scratch = Scratch::new("paths");
        let operator_home = operator_home();
        let error = cli_add(&[
            "x".into(),
            "--port".into(),
            "18995".into(),
            "--client-port".into(),
            "18996".into(),
            "--home".into(),
            operator_home.display().to_string(),
        ])
        .unwrap_err()
        .to_string();
        assert!(error.contains("operator home"), "{error}");

        let map = BTreeMap::from([("a".to_string(), sample("a", 18991, 18992, "master"))]);
        save(&map).expect("save");
        let error = cli_add(&[
            "b".into(),
            "--port".into(),
            "18993".into(),
            "--client-port".into(),
            "18994".into(),
            "--home".into(),
            "/tmp/a/nested".into(),
        ])
        .unwrap_err()
        .to_string();
        assert!(error.contains("overlaps"), "{error}");
    }

    #[test]
    fn a_nonempty_foreign_home_is_never_overwritten() {
        let _guard = env_guard();
        let scratch = Scratch::new("foreign");
        let foreign = scratch.dir.join("foreign-home");
        std::fs::create_dir_all(&foreign).unwrap();
        std::fs::write(foreign.join("precious.txt"), "do not lose me").unwrap();
        let error = cli_add(&[
            "x".into(),
            "--port".into(),
            "18997".into(),
            "--client-port".into(),
            "18998".into(),
            "--home".into(),
            foreign.display().to_string(),
        ])
        .unwrap_err()
        .to_string();
        assert!(error.contains("refusing to overwrite"), "{error}");
        assert!(foreign.join("precious.txt").exists());
    }

    #[test]
    fn a_corrupt_registry_is_an_error_and_is_not_overwritten() {
        let _guard = env_guard();
        let scratch = Scratch::new("corrupt");
        std::fs::write(scratch.registry(), "{ not json").unwrap();
        let before = std::fs::read(scratch.registry()).unwrap();
        assert!(load().is_err(), "a corrupt registry must not read as empty");
        let error = cli_add(&["x".into(), "--port".into(), "18991".into(), "--client-port".into(), "18992".into()])
            .unwrap_err()
            .to_string();
        assert!(!error.is_empty());
        assert_eq!(std::fs::read(scratch.registry()).unwrap(), before, "add must not overwrite a corrupt registry");
    }

    #[test]
    fn an_invalid_schema_or_entry_is_an_error() {
        let _guard = env_guard();
        let scratch = Scratch::new("schema");
        std::fs::write(scratch.registry(), r#"{"schema":2,"instances":{}}"#).unwrap();
        assert!(load().is_err());
        // name and key must agree
        std::fs::write(
            scratch.registry(),
            r#"{"schema":1,"instances":{"a":{"name":"b","home":"/tmp/a","install_dir":"/tmp/a/install","node_port":1,"client_port":2,"role":"master"}}}"#,
        )
        .unwrap();
        assert!(load().is_err());
        // a master must not bind a remote master
        std::fs::write(
            scratch.registry(),
            r#"{"schema":1,"instances":{"a":{"name":"a","home":"/tmp/a","install_dir":"/tmp/a/install","node_port":1,"client_port":2,"role":"master","master":"0123456789abcdef0123456789abcdef"}}}"#,
        )
        .unwrap();
        assert!(load().is_err());
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
        assert!(env.iter().any(|(key, value)| key == "WASM_AGENT_TRUSTED_MASTERS" && value == "0123456789abcdef0123456789abcdef"));
        std::env::remove_var("WA_TEST_SECRET_API_KEY");
    }

    #[test]
    fn shared_values_cross_only_when_declared_and_cannot_override_the_boundary() {
        let _guard = env_guard();
        let mut instance = sample("guest", 18996, 18997, "guest");
        instance
            .shared_env
            .insert("WASM_AGENT_RENDEZVOUS".into(), "https://example.invalid".into());
        // Even if a protected key somehow reached the map, the instance value is applied last.
        instance.shared_env.insert("WASM_AGENT_HOME".into(), "/tmp/operator".into());
        let env = guest_env(&instance);
        assert!(env.iter().any(|(key, value)| key == "WASM_AGENT_RENDEZVOUS" && value == "https://example.invalid"));
        assert!(env.iter().any(|(key, value)| key == "WASM_AGENT_HOME" && value == "/tmp/guest"));
    }

    #[test]
    fn lifecycle_records_must_be_complete_and_a_corrupt_one_is_an_error() {
        let _guard = env_guard();
        let scratch = Scratch::new("record");
        std::env::set_var("WASM_AGENT_HOME", &scratch.dir);
        // no record at all is Ok(None)
        assert!(read_record().expect("missing is not an error").is_none());
        // a corrupt record is an error, never a fallback
        let sentinel = crate::sentinel_dir();
        std::fs::write(sentinel.join("node.json"), "{ broken").unwrap();
        assert!(read_record().is_err());
        // an incomplete record is an error
        std::fs::write(
            sentinel.join("node.json"),
            r#"{"schema":1,"pid":1,"node_id":"","home":"/tmp/x","binary":"/tmp/x/wa","binary_sha256":"","started_at":0,"process_start":0}"#,
        )
        .unwrap();
        assert!(read_record().is_err());
        std::env::remove_var("WASM_AGENT_HOME");
    }

    #[test]
    fn a_purge_target_must_be_an_owned_home_and_not_the_operator() {
        let _guard = env_guard();
        let scratch = Scratch::new("purge");
        let error = validate_purge_target("x", &operator_home()).unwrap_err().to_string();
        assert!(error.contains("operator") || error.contains("marker"), "{error}");
        let foreign = scratch.dir.join("foreign");
        std::fs::create_dir_all(&foreign).unwrap();
        let error = validate_purge_target("x", &foreign).unwrap_err().to_string();
        assert!(error.contains("marker"), "{error}");
        let owned = scratch.dir.join("owned");
        std::fs::create_dir_all(owned.join(".wasm-agent")).unwrap();
        write_owned_marker(&owned, "x").unwrap();
        validate_purge_target("x", &owned).expect("an owned home may be purged");
    }
}
