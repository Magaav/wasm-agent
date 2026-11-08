//! The one feature resolver: "is this feature on, which path is live, and why" (docs/FEATURES.md).
//!
//! A component that is built and tested but never shipped is worse than one that does not exist: its
//! `WA_*_COMPONENT` flag silently falls back to the native path, so the node looks like it runs the
//! component and does not (the finding of 08/11 - `components.lock` pinned only `graph`, while
//! agent-core, selfloop, codemode, hooks, memory, model-gateway, telemetry-sink and wa-email were
//! built and never installed).
//!
//! So one resolver answers for every gate. Every surface - the Lua seams (`lua/core/*.lua`), the host
//! (`wa features`), the service capability (`services {"action":"features"}`) - asks *this* code, so
//! two surfaces cannot disagree about a node, and a feature that is on with nothing installed says so
//! by name (`component_missing`) instead of quietly running the native path.
//!
//! ## The rule
//!
//! ```text
//! enabled := env override, else policy.json `features.<id>`, else true (since 08/11)
//! active  := component  when enabled AND the component is installed with a verified pin
//!            native     otherwise, with the reason
//! ```
//!
//! * **on by default** (Victor, 08/11: "every new feature ON by default, each with a live per-feature
//!   off switch"). The features are built, tested and shipped (`components.lock` pins the whole set), so
//!   a node that has them installed runs them. `features.<id>: false` — or `WA_*_COMPONENT=0` — turns
//!   one off live, without a restart.
//! * **env wins** (`WA_MEMORY_COMPONENT=1`): a local experiment must not have to edit the policy file
//!   a deploy owns. `WA_*_COMPONENT=0` is as explicit as `=1` - "off, whatever the policy says".
//! * **the policy file is read live**, like the rest of it (`docs/GRANT-POLICY.md`, "The policy
//!   reload"): one stat per `WA_FEATURES_WATCH_MS` (default 1000) and a parse only when the file
//!   moved. Turning a feature off (or back on) is an edit to a file, never a restart.
//! * **default on is not "whatever happens to be installed".** `enabled` answers "may this node run the
//!   component", `active` answers "is it running it"; a feature that is enabled and has no verified
//!   component is `enabled: true, active: "native", reason: "component_missing"`, so a node that reads
//!   the table knows the component is not what is running, and the native path runs instead of crashing.
//!   A broken policy file or a non-boolean value is reported too, never guessed away.
//!
//! ## What this crate deliberately does not do
//!
//! It does not start, install or stop a component, and it does not cache an "active path" across a
//! change: [`status`] answers from the files as they are now. Installing is the deploy's job
//! (`scripts/lib/deploy-components.sh`), enabling is the operator's (the policy file), and running is
//! the gate's ([`active`]).

use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

/// One feature: what the policy calls it, which component backs it, and which native path runs when
/// it does not.
#[derive(Debug)]
pub struct FeatureSpec {
    /// The `policy.json` key and the name every surface prints (`memory`, `mesh_component`, …).
    pub id: &'static str,
    /// The component's file stem in the components directory and its `components.lock` name.
    pub component: &'static str,
    /// The environment override. `1`/`true`/`on`/`yes` forces the component, `0`/`false`/`off`/`no`
    /// forces the native path, and anything else is refused by name rather than guessed.
    pub env: &'static str,
    /// What runs when the feature is off or its component is missing - for the report only, so an
    /// operator reading `wa features` knows what they are on.
    pub native: &'static str,
    /// One line, no trailing period: what the feature switches.
    pub summary: &'static str,
}

/// Every feature this tree has a gate (or a built component) for. The order is the order the CLI and
/// the service answer print, and it is deliberate: the four seams the Lua core routes first, then the
/// node-level ones.
pub const FEATURES: &[FeatureSpec] = &[
    FeatureSpec {
        id: "selfloop",
        component: "selfloop",
        env: "WA_SELFLOOP_COMPONENT",
        native: "lua/core/selfloop.lua",
        summary: "the wake/notes/probe state machine (component) instead of the Lua one",
    },
    FeatureSpec {
        id: "codemode",
        component: "codemode",
        env: "WA_CODEMODE_COMPONENT",
        native: "lua/core/codemode.lua",
        summary: "the code-mode guest protocol and tool table (component) instead of the Lua loop",
    },
    FeatureSpec {
        id: "hooks",
        component: "hooks",
        env: "WA_HOOKS_COMPONENT",
        native: "lua/core/hooks.lua",
        summary: "hook matching, ordering and the mods surface (component) instead of the Lua engine",
    },
    FeatureSpec {
        id: "memory",
        component: "memory",
        env: "WA_MEMORY_COMPONENT",
        native: "lua/core/memory.lua",
        summary: "recall ranking, scope rules and retention (component) instead of the Lua store",
    },
    FeatureSpec {
        id: "gateway",
        component: "model-gateway",
        env: "WA_MODEL_GATEWAY_COMPONENT",
        native: "rust/wa-model-gateway",
        summary: "model routing, breakers and budgets (component) instead of the native gateway",
    },
    FeatureSpec {
        id: "mesh_component",
        component: "mesh",
        env: "WA_MESH_COMPONENT",
        native: "rust/wa-mesh",
        summary: "the mesh's admission and roster (component) instead of the native mesh",
    },
    FeatureSpec {
        id: "agent_core",
        component: "agent-core",
        env: "WA_AGENT_CORE_COMPONENT",
        native: "rust/wa-host",
        summary: "one agent turn (component) instead of the native core",
    },
    FeatureSpec {
        id: "telemetry_sink",
        component: "telemetry-sink",
        env: "WA_TELEMETRY_SINK_COMPONENT",
        native: "rust/wa-telemetry-sink",
        summary: "span/metric batching and the sink (component) instead of the native sink",
    },
];

/// The spec for a feature id, or `None` for a name nothing here knows. A caller that typed a feature
/// name gets an error, never a silent "off".
pub fn spec(id: &str) -> Option<&'static FeatureSpec> {
    FEATURES.iter().find(|f| f.id == id)
}

/// Where the answer came from. This is the part of the answer an operator needs to know *why* a node
/// runs what it runs, so it is printed verbatim.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// The `WA_*_COMPONENT` variable named this.
    Env,
    /// `policy.json`'s `features` section named this.
    Policy,
    /// Neither did: the default.
    Default,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Env => "env",
            Source::Policy => "policy",
            Source::Default => "default",
        }
    }
}

/// Which code answers a feature's calls right now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActivePath {
    /// The component, installed and pinned: the gate must route there.
    Component,
    /// The native path (the feature is off, or what backs it is not there).
    Native,
}

impl ActivePath {
    pub fn as_str(self) -> &'static str {
        match self {
            ActivePath::Component => "component",
            ActivePath::Native => "native",
        }
    }
}

/// What the components directory says about one component.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Installed {
    /// Present, and its bytes are the sha256 its pin names.
    Verified(String),
    /// No `<name>.wasm` in the directory.
    Missing,
    /// The bytes are there and are not the pinned ones (or the pin is missing/unreadable): a node in
    /// this state must not run it, and must not report it as installed (`docs/COMPONENTS.md`).
    PinMismatch(String),
}

impl Installed {
    pub fn sha(&self) -> Option<&str> {
        match self {
            Installed::Verified(sha) => Some(sha.as_str()),
            _ => None,
        }
    }
}

/// One feature's resolved state. `reason` is the whole point: it is why the path is the one it is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub id: &'static str,
    pub component: &'static str,
    pub env: &'static str,
    pub native: &'static str,
    pub summary: &'static str,
    pub enabled: bool,
    pub source: Source,
    pub installed: Installed,
    pub active: ActivePath,
    pub reason: String,
}

impl Status {
    /// The wire shape every surface prints. `installed` is the verified sha256 or `null`, so a reader
    /// that wants the pin gets the one this node checked rather than the one a file claims.
    pub fn to_json(&self) -> Value {
        json!({
            "feature": self.id,
            "component": self.component,
            "env": self.env,
            "enabled": self.enabled,
            "source": self.source.as_str(),
            "installed": self.installed.sha(),
            "active": self.active.as_str(),
            "reason": self.reason,
            "native": self.native,
            "summary": self.summary,
        })
    }
}

/// The truthy spellings an operator actually writes. Anything else is refused by
/// [`reason_env_invalid`] rather than read as "on" (a typo must not start a component) or as "off"
/// (a typo must not silently undo an operator's intent to enable one).
fn parse_flag(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "on" | "yes" => Some(true),
        "0" | "false" | "off" | "no" => Some(false),
        _ => None,
    }
}

/// The reason a feature is not on, or is on and native. Stable strings: they are matched by tests and
/// read by operators, so they are never reworded in place.
pub const REASON_COMPONENT: &str = "active_component";
/// `WA_*_COMPONENT=0` (or `features.<id>: false`): the operator turned it off, and the native path is
/// the answer.
pub const REASON_OFF: &str = "feature_off";
/// No env, no policy value: the feature is on because that is the default since 08/11. The reason name
/// is kept distinct from [`REASON_COMPONENT`] so "nobody said anything" stays distinguishable from
/// "the operator wrote `true`" on a node's table.
pub const REASON_DEFAULT_ON: &str = "default_on";
pub const REASON_COMPONENT_MISSING: &str = "component_missing";
pub const REASON_PIN_MISMATCH: &str = "component_pin_mismatch";
pub const REASON_ENV_INVALID: &str = "feature_env_invalid";
pub const REASON_VALUE_INVALID: &str = "feature_value_invalid";
pub const REASON_POLICY_UNREADABLE: &str = "features_unreadable";

/// The default when neither the environment nor the policy file names a feature (`docs/FEATURES.md`).
/// One constant, because every gate and every test must agree about it: 08/11 turned every feature on by
/// default, with the per-feature `false` as the switch.
pub const DEFAULT_ENABLED: bool = true;

/// What the policy file's `features` section says, including why it could not be read.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PolicyFeatures {
    /// `Some(true/false)` per feature id the file named with a boolean.
    pub values: Map<String, Value>,
    /// `Some(error)` when the file exists and could not be read or parsed as JSON: every feature then
    /// falls through to its default, and every reason says the file was the problem.
    pub error: Option<String>,
}

impl PolicyFeatures {
    /// One feature as the policy file answered it. `Err` carries the reason a value the file *did*
    /// name is unusable (a string, a number) - which is reported, never guessed.
    pub fn get(&self, id: &str) -> Result<Option<bool>, String> {
        match self.values.get(id) {
            None => Ok(None),
            Some(Value::Bool(value)) => Ok(Some(*value)),
            Some(other) => Err(format!("{REASON_VALUE_INVALID}:{id}:{other}")),
        }
    }
}

/// Resolve one feature from the three inputs, with no I/O. This is the whole rule, in one place, so
/// every surface and the tests agree by construction.
pub fn resolve(spec: &FeatureSpec, env: Option<&str>, policy: &PolicyFeatures, installed: &Installed) -> Status {
    let mut status = Status {
        id: spec.id,
        component: spec.component,
        env: spec.env,
        native: spec.native,
        summary: spec.summary,
        enabled: DEFAULT_ENABLED,
        source: Source::Default,
        installed: installed.clone(),
        active: ActivePath::Native,
        reason: REASON_DEFAULT_ON.to_string(),
    };
    // 1. the environment: an explicit 0/1 wins, an unusable value is refused by name.
    match env.map(parse_flag) {
        Some(Some(enabled)) => {
            status.enabled = enabled;
            status.source = Source::Env;
            status.reason = if enabled { REASON_COMPONENT.to_string() } else { REASON_OFF.to_string() };
        }
        Some(None) => {
            // Env names it and the value is not a flag: report, do not fall through to the policy
            // (falling through would turn a typo into "whatever the file says"), and **do not run the
            // component**: an unreadable statement about a component is not permission to start one.
            status.enabled = false;
            status.source = Source::Env;
            status.reason = REASON_ENV_INVALID.to_string();
            return status_with_path(status);
        }
        None => {
            // 2. the policy file.
            match policy.get(spec.id) {
                Ok(Some(enabled)) => {
                    status.enabled = enabled;
                    status.source = Source::Policy;
                    status.reason =
                        if enabled { REASON_COMPONENT.to_string() } else { REASON_OFF.to_string() };
                }
                Ok(None) => {
                    // 3. the default: on, and the component answers when it is there. A policy file that
                    // does not parse leaves every feature at that default and says why.
                    status.enabled = DEFAULT_ENABLED;
                    status.source = Source::Default;
                    status.reason = REASON_DEFAULT_ON.to_string();
                    if let Some(error) = &policy.error {
                        status.reason = format!("{REASON_POLICY_UNREADABLE}:{error}");
                    }
                }
                Err(reason) => {
                    // A value the file names that is not a boolean is an error, not a decision: the
                    // native path runs and the reason says why (same rule as an unusable env value).
                    status.enabled = false;
                    status.source = Source::Policy;
                    status.reason = reason;
                }
            }
        }
    }
    status_with_path(status)
}

/// The second half of the rule: an enabled feature is the component only when the component is really
/// there. Split out so the env/policy branch above cannot forget it.
fn status_with_path(mut status: Status) -> Status {
    if !status.enabled {
        status.active = ActivePath::Native;
        if status.reason == REASON_COMPONENT {
            // Unreachable by construction; kept because a wrong `reason` here would be a silent lie.
            status.reason = REASON_OFF.to_string();
        }
        return status;
    }
    match &status.installed {
        Installed::Verified(_) => {
            status.active = ActivePath::Component;
            // The reason keeps saying *why* it is on: "nobody turned it off" is a different statement
            // from "the operator turned it on", and the source column already carries the difference.
            if status.source != Source::Default {
                status.reason = REASON_COMPONENT.to_string();
            } else if status.reason == REASON_OFF {
                status.reason = REASON_DEFAULT_ON.to_string();
            }
        }
        Installed::Missing => {
            status.active = ActivePath::Native;
            status.reason = REASON_COMPONENT_MISSING.to_string();
        }
        Installed::PinMismatch(why) => {
            status.active = ActivePath::Native;
            status.reason = format!("{REASON_PIN_MISMATCH}:{why}");
        }
    }
    status
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The sha256 of a file's bytes, or `None` when it cannot be read.
pub fn file_sha256(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    Some(hex(ring::digest::digest(&ring::digest::SHA256, &bytes).as_ref()))
}

/// Is `component` installed and pinned in `dir`? The same test the kernel's `components::load`
/// applies, without loading the bytes into memory twice: the pin file's first token must be the
/// sha256 of the module beside it.
pub fn installed_in(dir: &Path, component: &str) -> Installed {
    let wasm = dir.join(format!("{component}.wasm"));
    let Ok(pin_text) = std::fs::read_to_string(dir.join(format!("{component}.wasm.sha256"))) else {
        return if wasm.is_file() { Installed::PinMismatch("component_pin_missing".into()) } else { Installed::Missing };
    };
    let declared = pin_text.split_whitespace().next().unwrap_or_default().to_ascii_lowercase();
    if declared.is_empty() {
        return Installed::PinMismatch("component_pin_empty".into());
    }
    let Some(actual) = file_sha256(&wasm) else {
        return Installed::Missing;
    };
    if actual == declared {
        Installed::Verified(actual)
    } else {
        Installed::PinMismatch(format!("component_hash_mismatch:pinned={declared}"))
    }
}

/// [`installed_in`] against the directory the kernel reads (`WA_COMPONENTS_DIR`, else
/// `~/.wasm-agent/components`), cached by the module's size and mtime so a per-call gate does not
/// re-hash an 8 MB component (the graph) on every operation.
pub fn installed(component: &str) -> Installed {
    // One entry per module: (path, len, mtime ms, answer). A named tuple because the point is that a
    // gate asks per call and must not re-hash 8 MB (the graph) to answer the same question twice.
    type CacheEntry = (PathBuf, u64, u64, Installed);
    static CACHE: OnceLock<Mutex<Vec<CacheEntry>>> = OnceLock::new();
    let dir = wa_host_support::paths::component_dir();
    let wasm = dir.join(format!("{component}.wasm"));
    let (len, mtime) = match std::fs::metadata(&wasm) {
        Ok(meta) => {
            let mtime = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            (meta.len(), mtime)
        }
        Err(_) => (0, 0),
    };
    let cache = CACHE.get_or_init(|| Mutex::new(Vec::new()));
    if let Ok(entries) = cache.lock() {
        if let Some((_, cached_len, cached_mtime, answer)) =
            entries.iter().find(|(path, _, _, _)| path == &wasm)
        {
            if *cached_len == len && *cached_mtime == mtime {
                return answer.clone();
            }
        }
    }
    let answer = installed_in(&dir, component);
    if let Ok(mut entries) = cache.lock() {
        entries.retain(|(path, _, _, _)| path != &wasm);
        entries.push((wasm, len, mtime, answer.clone()));
    }
    answer
}

/// The policy file the resolver reads: `WA_FEATURES_FILE` (a test, or an operator with the features
/// section somewhere else), else the grant policy's own file (`WA_GRANT_POLICY`, else
/// `<state>/policy.json`) - one file for "what this node may do" and "what this node routes".
pub fn policy_path() -> PathBuf {
    let env_path = |name: &str| std::env::var(name).ok().filter(|v| !v.is_empty()).map(PathBuf::from);
    if let Some(path) = env_path("WA_FEATURES_FILE") {
        return path;
    }
    if let Some(path) = env_path("WA_GRANT_POLICY") {
        return path;
    }
    let home = wa_host_support::paths::resolve_home();
    PathBuf::from(home).join(".wasm-agent").join("policy.json")
}

/// How often the file is re-stat'ed, unless `WA_FEATURES_WATCH_MS` says otherwise. One second is the
/// grant policy's own watch (`WA_GRANT_POLICY_WATCH_MS`), so a single file edit reaches every reader
/// of it at about the same moment.
fn watch_ms() -> u64 {
    std::env::var("WA_FEATURES_WATCH_MS").ok().and_then(|v| v.trim().parse::<u64>().ok()).unwrap_or(1000)
}

#[derive(Default, Clone)]
struct Fingerprint {
    mtime_ms: u64,
    len: u64,
    sha256: String,
}

/// The live view of the `features` section of one policy file.
///
/// A stat (not a parse) per [`watch_ms`]; a parse only when the file moved. `absent` is not an error:
/// a node with no policy file runs every feature off, which is today's behaviour.
#[derive(Default)]
pub struct PolicyView {
    path: Option<PathBuf>,
    fingerprint: Fingerprint,
    features: PolicyFeatures,
    checked_at_ms: u64,
}

impl PolicyView {
    /// A view of `path`, read immediately.
    pub fn new(path: &Path) -> PolicyView {
        let mut view = PolicyView { path: Some(path.to_path_buf()), ..Default::default() };
        view.refresh_at(now_ms(), true);
        view
    }

    /// A view of the node's policy file ([`policy_path`]), read immediately.
    pub fn node() -> PolicyView {
        PolicyView::new(&policy_path())
    }

    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// The last read's features. Reading is what [`refresh_at`](Self::refresh_at) does; this never
    /// touches the disk, so a caller that wants "the same answer as the gate" gets it.
    pub fn features(&self) -> &PolicyFeatures {
        &self.features
    }

    /// Re-read when the watch interval has passed (or `force`). Returns whether the file was re-parsed.
    pub fn refresh_at(&mut self, now: u64, force: bool) -> bool {
        if !force && now.saturating_sub(self.checked_at_ms) < watch_ms() {
            return false;
        }
        self.checked_at_ms = now;
        let Some(path) = self.path.clone() else { return false };
        let meta = match std::fs::symlink_metadata(&path) {
            Ok(meta) => Some(meta),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => {
                let changed = self.features.error.as_deref() != Some(&format!("stat:{error}"));
                self.features =
                    PolicyFeatures { values: Map::new(), error: Some(format!("stat:{error}")) };
                return changed;
            }
        };
        let Some(meta) = meta else {
            let changed = !self.fingerprint.sha256.is_empty() || self.features.error.is_some();
            self.fingerprint = Fingerprint::default();
            self.features = PolicyFeatures::default();
            return changed;
        };
        let mtime_ms = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        if !force
            && mtime_ms == self.fingerprint.mtime_ms
            && meta.len() == self.fingerprint.len
            && !self.fingerprint.sha256.is_empty()
        {
            return false; // the stat did not move: nothing to parse
        }
        let bytes = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) => {
                self.features = PolicyFeatures { values: Map::new(), error: Some(format!("read:{error}")) };
                return true;
            }
        };
        let sha = hex(ring::digest::digest(&ring::digest::SHA256, &bytes).as_ref());
        self.fingerprint = Fingerprint { mtime_ms, len: bytes.len() as u64, sha256: sha };
        self.features = parse_features(&bytes);
        true
    }

    /// [`refresh_at`](Self::refresh_at) with the clock read here.
    pub fn refresh(&mut self) -> bool {
        self.refresh_at(now_ms(), false)
    }

    /// Resolve one feature against this view's live file (refreshing first) and the components
    /// directory.
    pub fn status(&mut self, id: &str) -> Option<Status> {
        let spec = spec(id)?;
        self.refresh();
        let env = std::env::var(spec.env).ok();
        Some(resolve(spec, env.as_deref(), &self.features, &installed(spec.component)))
    }

    /// Every feature, resolved against this view.
    pub fn all(&mut self) -> Vec<Status> {
        self.refresh();
        FEATURES
            .iter()
            .map(|spec| {
                let env = std::env::var(spec.env).ok();
                resolve(spec, env.as_deref(), &self.features, &installed(spec.component))
            })
            .collect()
    }
}

/// The `features` object of a policy document, or an error naming what is wrong with it. A document
/// without a `features` member is not an error (every feature keeps its default); a `features` member
/// that is not an object is (a typo must not read as "all off by policy").
pub fn parse_features(bytes: &[u8]) -> PolicyFeatures {
    let text = match std::str::from_utf8(bytes) {
        Ok(text) => text,
        Err(_) => return PolicyFeatures { values: Map::new(), error: Some("not_utf8".into()) },
    };
    let document: Value = match serde_json::from_str(text) {
        Ok(value) => value,
        Err(error) => {
            return PolicyFeatures { values: Map::new(), error: Some(format!("json:{error}")) }
        }
    };
    match document.get("features") {
        None | Some(Value::Null) => PolicyFeatures::default(),
        Some(Value::Object(map)) => PolicyFeatures { values: map.clone(), error: None },
        Some(other) => {
            PolicyFeatures { values: Map::new(), error: Some(format!("not_an_object:{other}")) }
        }
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// The node's resolver: one [`PolicyView`] for the process, so the per-call read is one stat a second
/// no matter how many gates ask.
fn node_view() -> &'static Mutex<PolicyView> {
    static VIEW: OnceLock<Mutex<PolicyView>> = OnceLock::new();
    VIEW.get_or_init(|| Mutex::new(PolicyView::node()))
}

/// Every feature, as the node resolves it right now.
pub fn status_all() -> Vec<Status> {
    match node_view().lock() {
        Ok(mut view) => view.all(),
        // A poisoned lock is a panic in another thread, not a feature decision: answer from a fresh
        // read rather than reporting something invented.
        Err(_) => PolicyView::node().all(),
    }
}

/// One feature, as the node resolves it right now. `None` for a name nothing here knows.
pub fn status(id: &str) -> Option<Status> {
    match node_view().lock() {
        Ok(mut view) => view.status(id),
        Err(_) => PolicyView::node().status(id),
    }
}

/// What a gate asks: the component answers this feature's calls. `false` means the native path, and
/// [`status`] says why - a gate that falls back never does it silently.
pub fn active(id: &str) -> bool {
    status(id).map(|s| s.active == ActivePath::Component).unwrap_or(false)
}

/// [`active`] plus the reason, for a gate that wants to log the fallback once.
pub fn active_reason(id: &str) -> (bool, String) {
    match status(id) {
        Some(status) => (status.active == ActivePath::Component, status.reason),
        None => (false, format!("unknown_feature:{id}")),
    }
}

/// The wire document every surface prints: `{"ok":true,"features":[…],"policy":"<file>"}`, plus the
/// policy file's error when it has one (so "all features off" cannot be a quiet way of hiding a
/// policy file someone half-wrote).
pub fn status_value(list: &[Status], policy: &Path) -> Value {
    let features: Vec<Value> = list.iter().map(Status::to_json).collect();
    let mut document = json!({
        "ok": true,
        "policy": policy.to_string_lossy(),
        "features": features,
    });
    let mut view = PolicyView::new(policy);
    view.refresh_at(now_ms(), true);
    if let Some(error) = view.features().error.clone() {
        document["policy_error"] = Value::String(error);
    }
    document
}

/// [`status_value`] as text, for a caller that pushes a string (the Lua capability).
pub fn status_json(list: &[Status], policy: &Path) -> String {
    serde_json::to_string(&status_value(list, policy)).expect("features status is serializable")
}

/// The whole node's answer as a JSON value (`services {"action":"features"}`).
pub fn node_value() -> Value {
    status_value(&status_all(), &policy_path())
}

/// The whole node's answer, as JSON text (`wa features --json`, `host.features()`).
pub fn node_json() -> String {
    serde_json::to_string(&node_value()).expect("features status is serializable")
}

/// One feature's answer as a JSON value, or a refusal naming the unknown id.
pub fn feature_value(id: &str) -> Value {
    match status(id) {
        Some(status) => json!({"ok": true, "feature": status.to_json()}),
        None => json!({"ok": false, "error": format!("unknown_feature:{id}")}),
    }
}

/// One feature's answer as JSON text - the shape a gate reads
/// (`host.features({"feature":"memory"})`).
pub fn feature_json(id: &str) -> String {
    serde_json::to_string(&feature_value(id)).expect("feature status is serializable")
}

/// The human table `wa features` prints: one line per feature, then what the policy file says about
/// itself. Reason is last because it is the answer to "why", and it is the column that must never be
/// empty.
pub fn status_text(list: &[Status], policy: &Path) -> String {
    let mut text = String::new();
    text.push_str("feature           component        installed  enabled  source   active     reason\n");
    for status in list {
        let installed = match &status.installed {
            Installed::Verified(sha) => sha.chars().take(10).collect::<String>(),
            Installed::Missing => "-".to_string(),
            Installed::PinMismatch(_) => "mismatch".to_string(),
        };
        text.push_str(&format!(
            "{:<17} {:<16} {:<10} {:<8} {:<8} {:<10} {}\n",
            status.id,
            status.component,
            installed,
            if status.enabled { "yes" } else { "no" },
            status.source.as_str(),
            status.active.as_str(),
            status.reason,
        ));
    }
    text.push_str(&format!("policy: {}\n", policy.display()));
    let mut view = PolicyView::new(policy);
    view.refresh_at(now_ms(), true);
    match &view.features().error {
        Some(error) => text.push_str(&format!("policy error: {error}\n")),
        // An absent file is not an error and must not read like a decision: since 08/11 the default is
        // *on*, so "no file" means the node runs its shipped features, and the table above says so.
        None if !policy.exists() => {
            text.push_str("policy: absent (no file: every feature keeps its default, which is on)\n")
        }
        None => text.push_str("policy: features section read\n"),
    }
    text
}

#[cfg(test)]
mod tests;
