//! The node's grant policy, wired (docs/GRANT-POLICY.md "How the host wires it").
//!
//! One [`Engine`] and one pair of sinks per node: the durable JSONL audit trail in the bounded
//! `<state>/audit/` directory and a 512-record ring the operator view can read. Every sensitive
//! host call asks this module before it does anything; the answer is the crate's [`Decision`], and
//! the call sites are where a `Deny` becomes a `refused` error for the guest.
//!
//! Loaded once, lazily, on the first check or the first `host.policy_status`, and then **watched**: the
//! file's mtime/size/sha256 is checked once a second and a change is parsed, validated and swapped into
//! the running engine with its budgets kept ([`NodePolicy::reload`]). Why: on 06/11 a deploy wrote
//! `policy.json` 24 s after the node had started and the node kept the old policy for its whole life,
//! refusing every send with a rule the operator had just written (`docs/KERNEL.md`, "The policy reload").
//!
//! * `WA_GRANT_POLICY` (else `<state>/policy.json`). **The presence of that file is what turns the
//!   policy layer on**, and that is deliberate: installing a new binary must never take capabilities
//!   away from a node that runs (`docs/GRANT-POLICY.md`, "Manifest mode").
//!   * **absent** → [`Mode::Manifest`]: the manifest grant stays the only gate, exactly the behaviour
//!     before the policy layer existed. Nothing is refused for want of a rule; every check is still
//!     counted and the default-sensitive ones are audited with the reason `manifest_mode`; one
//!     warning is written to the node's log at load.
//!   * **present and parseable** → [`Mode::Policy`]: a rule the operator wrote is enforced, and a
//!     sensitive capability **with no rule is refused** with `no_policy` (the crate's default).
//!   * **present and broken** → also [`Mode::Policy`], with an empty policy plus one line on the
//!     node's log: the node starts, the capabilities the policy governs are refused with
//!     `no_policy`, and the error is visible in `host.policy_status`. A `policy.json` an operator
//!     half-wrote must not silently fall back to "no limits" - that is the failure this layer
//!     exists to prevent. Only a file that is *not there at all* means manifest mode.
//! * `WA_GRANT_POLICY_STATE` (else `<state>/grant-policy.state.json`) restores the budgets
//!   (buckets, daily counters, approvals); a missing file is fresh budgets. It is written on the
//!   tick (every five minutes) so a restart continues the same limits.
//!
//! Nothing here reads a clock: `now_ms` is read once per check and passed to the crate, exactly as
//! the library requires. No `await` is ever held with the engine's lock (WASI 0.3 note).
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use wa_grant_policy::{
    AuditError, AuditRecord, AuditSink, Decision, Engine, FileAudit, MemoryAudit, PolicySet, TargetMode,
    DEFAULT_SENSITIVE,
};

/// Why a decided-in-manifest-mode record says what it says (`docs/GRANT-POLICY.md`, "Manifest mode").
/// It rides in the audit record's `reason` field, so a reader can tell a call the manifest alone
/// allowed from one a written rule allowed.
pub const MANIFEST_REASON: &str = "manifest_mode";

/// Which gate decides a sensitive capability the policy file names no rule for.
///
/// The mode is decided once, at load, by whether the policy file is there - see the module docs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// No policy file: the manifest grant is the only gate (`docs/GRANT-POLICY.md`, "Manifest
    /// mode"). Today's behaviour for a node that never wrote a policy.
    Manifest,
    /// A policy file is loaded: a sensitive capability with no rule is refused with `no_policy`.
    Policy,
}

impl Mode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Mode::Manifest => "manifest",
            Mode::Policy => "policy",
        }
    }

    fn code(&self) -> u8 {
        match self {
            Mode::Manifest => 0,
            Mode::Policy => 1,
        }
    }

    fn from_code(code: u8) -> Mode {
        if code == 1 {
            Mode::Policy
        } else {
            Mode::Manifest
        }
    }
}

/// What a reload did. `changed` is "the file on disk is not the one the loaded policy came from",
/// which is what a watcher reports; `applied` is "the loaded policy was replaced by it".
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reload {
    pub changed: bool,
    pub applied: bool,
    pub mode: Mode,
    /// The sha256 of the file the *loaded* policy came from (`"absent"` when there was none).
    pub sha256: String,
    /// Why the file was not applied, when it was not (`policy_removed`, a parse error, an I/O error).
    pub error: Option<String>,
}

/// The file the loaded policy came from: mtime, size and sha256. A reload compares this before it
/// parses anything, so a 1 s watch costs one stat and, only when the stat moved, one hash.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Fingerprint {
    mtime_ms: u64,
    len: u64,
    sha256: String,
}

fn fingerprint(path: &std::path::Path) -> Result<Fingerprint, String> {
    let meta = std::fs::symlink_metadata(path).map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            "absent".to_string()
        } else {
            format!("stat:{e}")
        }
    })?;
    let bytes = std::fs::read(path).map_err(|e| format!("read:{e}"))?;
    let hex: String = ring::digest::digest(&ring::digest::SHA256, &bytes).as_ref().iter().map(|b| format!("{b:02x}")).collect();
    let mtime_ms = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    Ok(Fingerprint { mtime_ms, len: bytes.len() as u64, sha256: hex })
}
/// How many of the last refusals the operator view keeps (component, capability, reason only —
/// never a target, which is the whole point of the digest in the audit record).
const REFUSAL_RING: usize = 32;
/// The in-memory audit ring `host.policy_status` can read (`docs/GRANT-POLICY.md` step 2).
const MEMORY_AUDIT_RECORDS: usize = 512;
/// How often the tick writes the state snapshot.
const STATE_SAVE_MS: u64 = 5 * 60 * 1000;

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Where a node's policy files live.
#[derive(Clone, Debug)]
pub struct Paths {
    pub policy: PathBuf,
    pub state: PathBuf,
    pub audit: PathBuf,
}

impl Paths {
    pub fn resolve() -> Paths {
        let root = crate::store::state_root();
        Paths {
            policy: std::env::var("WA_GRANT_POLICY")
                .ok()
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| root.join("policy.json")),
            state: std::env::var("WA_GRANT_POLICY_STATE")
                .ok()
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| root.join("grant-policy.state.json")),
            audit: crate::store::audit_file().unwrap_or_else(|_| root.join("audit").join("grant-policy.jsonl")),
        }
    }
}

/// The top-level sections of `policy.json` whose schema another crate owns, so this node's loader can
/// say whether one is usable. `mesh` is `wa-mesh-core`'s (`docs/MESH.md`); a section nothing registers
/// is carried and reported, never a reason to refuse the rules (`docs/GRANT-POLICY.md`, "Sections this
/// crate does not read").
fn section_owners() -> Vec<wa_grant_policy::SectionOwner> {
    vec![wa_mesh_core::policy::section_owner()]
}

/// What the loaded file's *other* sections are, and what is wrong with the ones that are wrong.
#[derive(Default, Clone, Debug)]
struct Sections {
    carried: Vec<String>,
    errors: BTreeMap<String, String>,
}

fn sections_of(policy: &PolicySet, owners: &[wa_grant_policy::SectionOwner]) -> Sections {
    let mut carried: Vec<String> = policy.sections.keys().cloned().collect();
    carried.sort();
    Sections { carried, errors: policy.section_errors.clone() }
}

/// The loud half: one line per unusable section, at load and at every reload that changes the answer.
/// An invalid section is reported by name and never silently ignored - and it never takes the capability
/// rules down with it (the 08/11 incident: a `mesh` section made every `wa-whatsapp` rule unreadable).
fn report_sections(path: &std::path::Path, sections: &Sections) {
    for (name, why) in &sections.errors {
        eprintln!(
            "[policy] {}: section `{name}` is unusable: {why} (the capability rules beside it are still in force; docs/GRANT-POLICY.md)",
            path.display()
        );
    }
}

#[derive(Default)]
struct Counters {
    checks: AtomicU64,
    allow: AtomicU64,
    deny: AtomicU64,
    rate_limited: AtomicU64,
    needs_approval: AtomicU64,
    /// Decisions the manifest alone answered (`Mode::Manifest`), i.e. the checks no policy file
    /// governed. Counted apart from `allow` so "the policy layer is off" is visible, not inferred.
    manifest_mode: AtomicU64,
    audit_errors: AtomicU64,
}

/// The two sinks, written in one order: the durable file first (a failure there is what
/// fail-closed acts on), then the ring the operator view reads.
struct TeeAudit {
    file: Option<FileAudit>,
    file_error: Option<String>,
    memory: MemoryAudit,
}

impl AuditSink for TeeAudit {
    fn write(&mut self, record: &AuditRecord) -> Result<(), AuditError> {
        let _ = self.memory.write(record);
        match self.file.as_mut() {
            Some(file) => file.write(record),
            // The trail is the durable evidence; if it could not be opened a sensitive call is
            // refused (`audit_unavailable`) instead of running unaudited.
            None => Err(AuditError {
                sink: "file",
                detail: self.file_error.clone().unwrap_or_else(|| "audit file not open".into()),
            }),
        }
    }
}

struct Refusal {
    ts_ms: u64,
    component: String,
    capability: String,
    reason: String,
}

/// One node's policy: the engine, its sinks, the counters the operator reads.
pub struct NodePolicy {
    engine: Mutex<Engine>,
    audit: Mutex<TeeAudit>,
    counters: Counters,
    refusals: Mutex<VecDeque<Refusal>>,
    /// One log line per (component, capability) per second: a loop that is refused 10 000 times
    /// must not produce 10 000 log lines.
    logged: Mutex<HashMap<String, u64>>,
    paths: Paths,
    /// What turns the policy layer on: a policy file that is present (`Mode::Policy`) or not
    /// (`Mode::Manifest`). Fixed at load; a reload is a new process.
    ///
    /// Behind an atomic since the reload (`docs/KERNEL.md`, "The policy reload"): a policy file that
    /// appears while the node runs switches the layer on, and one that is tightened switches the
    /// rules - which is the production bug this reload closes (a node started 14:55:13, the file
    /// written 14:55:37, and every send denied afterwards).
    mode: AtomicU8,
    /// A policy file parsed. `false` also for a file that is present but broken - read `mode` for
    /// "is the policy layer on at all".
    loaded: AtomicBool,
    load_error: Mutex<Option<String>>,
    /// The file's other sections (`mesh`, `vault`, `models`, a future one): which are carried, and which
    /// one is unusable and why. Reported in `host.policy_status` and logged - never a reason to drop the
    /// capability rules beside them.
    sections: Mutex<Sections>,
    /// The file the loaded policy came from, and what the watcher last looked at.
    fingerprint: Mutex<Fingerprint>,
    reloads: AtomicU64,
    reload_checked_at_ms: AtomicU64,
    /// The last reload that found a change, whether it was applied or refused.
    last_reload: Mutex<Option<(u64, Reload)>>,
    last_save_ms: AtomicU64,
}

impl NodePolicy {
    /// Load the policy file and restore the budgets. Never fails: a policy that cannot be read is
    /// reported and behaves as an empty one.
    ///
    /// **Only a file that is absent selects [`Mode::Manifest`].** A file that is there and does not
    /// parse, and a file that cannot be read (permissions, I/O), both select [`Mode::Policy`] with an
    /// empty policy: the answered question is then "default deny for the sensitive capabilities" and
    /// the error is on the node's log and in `host.policy_status`. A policy file this node cannot
    /// understand is not evidence that the operator wants no limits.
    pub fn open(paths: Paths) -> NodePolicy {
        // The fingerprint of the file this load read, so the first reload check after a start does
        // not re-parse (and re-log) the same bytes. `absent` is a fingerprint too: a file that
        // appears later is a change.
        let loaded_fingerprint = fingerprint(&paths.policy).unwrap_or_default();
        let owners = section_owners();
        let mut sections = Sections::default();
        let (policy, mode, loaded, load_error) = match std::fs::read(&paths.policy) {
            Ok(bytes) => match PolicySet::parse_owned(&String::from_utf8_lossy(&bytes), &owners) {
                Ok(policy) => {
                    sections = sections_of(&policy, &owners);
                    (policy, Mode::Policy, true, None)
                }
                Err(error) => {
                    eprintln!("[policy] {}: {error}", paths.policy.display());
                    (PolicySet::empty(), Mode::Policy, false, Some(error.to_string()))
                }
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                (PolicySet::empty(), Mode::Manifest, false, None)
            }
            Err(error) => {
                eprintln!("[policy] {}: {error}", paths.policy.display());
                (PolicySet::empty(), Mode::Policy, false, Some(format!("{}: {error}", paths.policy.display())))
            }
        };
        if mode == Mode::Manifest {
            // One line, at load, not one per call: this is a statement about the node's
            // configuration, and an operator who wants the limits writes the file.
            eprintln!(
                "[policy] {MANIFEST_REASON}: no policy file at {} - the manifest grant is the only gate for sensitive capabilities; decisions are counted and audited as {MANIFEST_REASON} (docs/GRANT-POLICY.md)",
                paths.policy.display()
            );
        }
        report_sections(&paths.policy, &sections);
        let mut engine = Engine::new(policy);
        if let Ok(text) = std::fs::read_to_string(&paths.state) {
            if let Err(error) = engine.restore_json(&text) {
                eprintln!("[policy] {}: {error} (starting with fresh budgets)", paths.state.display());
            }
        }
        let audit = match FileAudit::open(paths.audit.clone(), crate::store::AUDIT_ROTATE_BYTES) {
            Ok(file) => TeeAudit { file: Some(file), file_error: None, memory: MemoryAudit::with_limit(MEMORY_AUDIT_RECORDS) },
            Err(error) => {
                eprintln!("[policy] audit trail unavailable at {}: {error}", paths.audit.display());
                TeeAudit { file: None, file_error: Some(error.to_string()), memory: MemoryAudit::with_limit(MEMORY_AUDIT_RECORDS) }
            }
        };
        NodePolicy {
            engine: Mutex::new(engine),
            audit: Mutex::new(audit),
            counters: Counters::default(),
            refusals: Mutex::new(VecDeque::new()),
            logged: Mutex::new(HashMap::new()),
            paths,
            mode: AtomicU8::new(mode.code()),
            loaded: AtomicBool::new(loaded),
            load_error: Mutex::new(load_error),
            sections: Mutex::new(sections),
            fingerprint: Mutex::new(loaded_fingerprint),
            reloads: AtomicU64::new(0),
            reload_checked_at_ms: AtomicU64::new(0),
            last_reload: Mutex::new(None),
            last_save_ms: AtomicU64::new(0),
        }
    }

    /// Which gate decides an unruled sensitive capability on this node (`Mode::Manifest` until a
    /// policy file is written).
    pub fn mode(&self) -> Mode {
        Mode::from_code(self.mode.load(Ordering::Relaxed))
    }

    /// Is a policy file loaded (as opposed to "the file was absent at load")?
    pub fn is_loaded(&self) -> bool {
        self.loaded.load(Ordering::Relaxed)
    }

    /// The reload's own view: did the file on disk move away from the loaded one?
    ///
    /// This is the fix for the 06/11 production bug (`docs/KERNEL.md`, "The policy reload"): a deploy
    /// installed `policy.json` 24 s after the node started, and the node kept enforcing the policy it
    /// had loaded at 14:55:13 - every WhatsApp send denied afterwards, with nothing on the node
    /// saying why. Two fixes, both needed: the deploy installs the policy *before* it restarts the
    /// node (`scripts/deploy.sh`), and the node reloads the file when it changes (here).
    ///
    /// The swap is atomic in the only sense that matters: a new [`PolicySet`] is parsed and
    /// validated *first*, then installed under the engine's lock with `set_policy`, which keeps the
    /// budgets (rate buckets, daily counters, approvals). A parse error applies nothing and is
    /// reported - a half-written file never replaces a working policy, and never falls back to
    /// "no limits" either (
    /// `Mode::Manifest` is only ever the answer to "there is no file at load time").
    pub fn reload(&self) -> Reload {
        self.reload_at(now_ms())
    }

    /// `reload` with the clock passed in, so a test never waits for one.
    pub fn reload_at(&self, now: u64) -> Reload {
        self.reload_checked_at_ms.store(now, Ordering::Relaxed);
        let current = match fingerprint(&self.paths.policy) {
            Ok(current) => current,
            Err(error) if error == "absent" => Fingerprint::default(),
            Err(error) => {
                // The file is there and cannot be read: keep what is loaded (fail closed) and say so.
                let reload = Reload {
                    changed: true,
                    applied: false,
                    mode: self.mode(),
                    sha256: self.fingerprint.lock().unwrap_or_else(|e| e.into_inner()).sha256.clone(),
                    error: Some(error),
                };
                self.note_reload(now, &reload);
                return reload;
            }
        };
        let previous = self.fingerprint.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if current == previous {
            return Reload { changed: false, applied: false, mode: self.mode(), sha256: current.sha256, error: None };
        }
        // The file was removed while the node ran. Going back to `Mode::Manifest` here would *widen*
        // what the node allows, which is the opposite of what a reload is for; the loaded policy
        // stays until the next start, and the operator sees why.
        if current == Fingerprint::default() {
            let reload = Reload {
                changed: true,
                applied: false,
                mode: self.mode(),
                sha256: "absent".into(),
                error: Some("policy_removed: keeping the loaded policy until the next start".into()),
            };
            *self.fingerprint.lock().unwrap_or_else(|e| e.into_inner()) = current;
            self.note_reload(now, &reload);
            return reload;
        }
        let bytes = match std::fs::read(&self.paths.policy) {
            Ok(bytes) => bytes,
            Err(error) => {
                let reload = Reload { changed: true, applied: false, mode: self.mode(), sha256: current.sha256, error: Some(format!("read:{error}")) };
                self.note_reload(now, &reload);
                return reload;
            }
        };
        let policy = match PolicySet::parse_owned(&String::from_utf8_lossy(&bytes), &section_owners()) {
            Ok(policy) => policy,
            Err(error) => {
                // Keep the working policy: a broken write is a bug to fix, not a reason to run
                // unaudited and unruled. The fingerprint is *not* advanced, so fixing the file is
                // one more check away rather than a restart away.
                let reload = Reload { changed: true, applied: false, mode: self.mode(), sha256: current.sha256, error: Some(error.to_string()) };
                self.note_reload(now, &reload);
                return reload;
            }
        };
        let apply = self.engine().set_policy(policy);
        match apply {
            Ok(()) => {
                self.mode.store(Mode::Policy.code(), Ordering::Relaxed);
                self.loaded.store(true, Ordering::Relaxed);
                *self.load_error.lock().unwrap_or_else(|e| e.into_inner()) = None;
                // The sections are re-read with the rules: a `mesh` section fixed by the operator is a
                // section that stops being reported on the next tick, exactly like a rule.
                let owners = section_owners();
                let sections = {
                    let engine = self.engine();
                    sections_of(engine.policy(), &owners)
                };
                let changed_error = {
                    let mut held = self.sections.lock().unwrap_or_else(|e| e.into_inner());
                    let changed = held.errors != sections.errors;
                    *held = sections.clone();
                    changed
                };
                if changed_error {
                    report_sections(&self.paths.policy, &sections);
                }
                *self.fingerprint.lock().unwrap_or_else(|e| e.into_inner()) = current.clone();
                self.reloads.fetch_add(1, Ordering::Relaxed);
                eprintln!("[policy] reloaded {} (sha256 {}…)", self.paths.policy.display(), &current.sha256[..12.min(current.sha256.len())]);
                let reload = Reload { changed: true, applied: true, mode: Mode::Policy, sha256: current.sha256, error: None };
                self.note_reload(now, &reload);
                reload
            }
            Err(error) => {
                let reload = Reload { changed: true, applied: false, mode: self.mode(), sha256: current.sha256, error: Some(error.to_string()) };
                self.note_reload(now, &reload);
                reload
            }
        }
    }

    fn note_reload(&self, now: u64, reload: &Reload) {
        if let Some(error) = &reload.error {
            eprintln!("[policy] {} not reloaded: {error}", self.paths.policy.display());
            *self.load_error.lock().unwrap_or_else(|e| e.into_inner()) = Some(error.clone());
        }
        *self.last_reload.lock().unwrap_or_else(|e| e.into_inner()) = Some((now, reload.clone()));
    }

    /// The sha256 of the file the loaded policy came from (`"absent"` when there was none).
    pub fn policy_sha256(&self) -> String {
        let fingerprint = self.fingerprint.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if fingerprint == Fingerprint::default() {
            "absent".into()
        } else {
            fingerprint.sha256
        }
    }

    /// Start the reload watcher for one policy instance, once per process. `WA_GRANT_POLICY_WATCH_MS=0`
    /// turns it off. The thread holds an `Arc` for the process's lifetime, so it never outlives what
    /// it watches.
    pub fn spawn_watcher(policy: &std::sync::Arc<NodePolicy>) {
        let Some(interval) = watch_interval() else { return };
        static STARTED: AtomicBool = AtomicBool::new(false);
        if STARTED.swap(true, Ordering::SeqCst) {
            return;
        }
        let watched = policy.clone();
        let _ = std::thread::Builder::new().name("wa-policy-reload".into()).spawn(move || loop {
            std::thread::sleep(interval);
            // A reload that finds nothing new does no work beyond one stat; a change is applied (or
            // refused) under the engine's lock, so a check never sees half a policy.
            let _ = watched.reload();
        });
    }

    fn engine(&self) -> MutexGuard<'_, Engine> {
        self.engine.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Audit one call the **caller** decided to refuse without asking the engine: a manifest grant the
    /// component never declared, an interface this node never serves, a host path a preopen may not
    /// name. One audit record with the caller's reason word, counted as a denial, and never a budget
    /// charge - nothing was allowed, so nothing is spent.
    ///
    /// Why this exists: `docs/WASI-INTERFACES.md` puts the *manifest* gate in front of the policy
    /// layer, so the interesting event ("this component asked for something its artifact never
    /// declared") never reaches [`NodePolicy::check_at`]. Without this the trail would show only the
    /// refusals a rule produced, and the outline of a component trying to widen itself would be
    /// missing. The target is digested exactly as everywhere else.
    pub fn record_deny_at(&self, component: &str, capability: &str, target: Option<&str>, reason: &str, now: u64) {
        self.counters.checks.fetch_add(1, Ordering::Relaxed);
        let decision = Decision::Deny(wa_grant_policy::Reason::NoPolicy);
        let mut record = AuditRecord::new(now, component, capability, target, &decision, TargetMode::Digest);
        record.reason = reason.chars().take(64).collect();
        let written = self.audit.lock().unwrap_or_else(|e| e.into_inner()).write(&record);
        if let Err(error) = written {
            // The trail is the evidence; a refusal that cannot be written is still a refusal.
            self.counters.audit_errors.fetch_add(1, Ordering::Relaxed);
            self.say(&format!("audit\u{1f}{reason}"), &format!("[policy] audit_error ({reason}): sink {}: {}", error.sink, error.detail), now);
        }
        self.count(component, capability, &decision, now);
    }

    /// Check one sensitive call and audit it. The budget is charged only on `Allow`.
    ///
    /// In [`Mode::Manifest`] the answer is `Allow` - the manifest grant, which the caller has already
    /// applied, is the only gate - and the call is still counted (`decisions.manifest_mode`) and, for
    /// a capability that is sensitive by default, audited with reason [`MANIFEST_REASON`].
    pub fn check_at(&self, component: &str, capability: &str, target: Option<&str>, now: u64) -> Decision {
        self.counters.checks.fetch_add(1, Ordering::Relaxed);
        if self.mode() == Mode::Manifest {
            self.record_manifest_at(component, capability, target, now);
            self.counters.manifest_mode.fetch_add(1, Ordering::Relaxed);
            let decision = Decision::Allow;
            self.count(component, capability, &decision, now);
            return decision;
        }
        let decision = {
            let mut engine = self.engine();
            let mut audit = self.audit.lock().unwrap_or_else(|e| e.into_inner());
            engine.enforce(component, capability, target, now, &mut *audit)
        };
        self.count(component, capability, &decision, now);
        decision
    }

    /// Audit one manifest-mode decision. Sensitive-by-default capabilities are the ones a policy
    /// file would audit, so the trail keeps the same shape either way; an ordinary capability (a kv
    /// read, a log line) is counted and not written, which is also what a rule-less policy does.
    /// A write failure is counted and logged, and **never refuses the call**: in manifest mode the
    /// manifest grant is the only gate, so a full audit disk must not stop a working component.
    fn record_manifest_at(&self, component: &str, capability: &str, target: Option<&str>, now: u64) {
        if !DEFAULT_SENSITIVE.contains(&capability) {
            return;
        }
        let mut record = AuditRecord::new(now, component, capability, target, &Decision::Allow, TargetMode::Digest);
        record.reason = MANIFEST_REASON.to_string();
        let written = self.audit.lock().unwrap_or_else(|e| e.into_inner()).write(&record);
        if let Err(error) = written {
            self.counters.audit_errors.fetch_add(1, Ordering::Relaxed);
            self.say(
                &format!("audit\u{1f}{MANIFEST_REASON}"),
                &format!("[policy] audit_error ({MANIFEST_REASON}): sink {}: {}", error.sink, error.detail),
                now,
            );
        }
    }

    /// Enforce a rule **only when the operator wrote one** for this component/capability. This is
    /// the shape used on the wasi-socket path of request components: the manifest grant already
    /// answered "may it reach this address", so an absent rule must not turn a working component
    /// into a refused one, while a rule the operator did write is enforced.
    pub fn check_if_ruled_at(&self, component: &str, capability: &str, target: Option<&str>, now: u64) -> Decision {
        // The guard is dropped before `check_at` takes the engine again.
        let ruled = {
            let engine = self.engine();
            engine.policy().rule(component, capability).is_some()
        };
        if !ruled {
            return Decision::Allow;
        }
        self.check_at(component, capability, target, now)
    }

    /// The interim `whatsapp.send` check for an opaque frame (`docs/GRANT-POLICY.md`, "The honest
    /// gap"): the host sees `websocket.send(data)` and not the chat, so the capability-wide budget
    /// is all it can charge. That is charged only for a rule that names **no targets** (`allow`
    /// empty) - which is exactly how an operator writes "global cap only, no per-chat claim".
    pub fn check_opaque_send_at(&self, component: &str, authority: &str, now: u64) -> Decision {
        let frame = self.check_at(component, "net.send", Some(authority), now);
        if !frame.is_allow() {
            return frame;
        }
        let global_only = {
            let engine = self.engine();
            engine
                .policy()
                .rule(component, "whatsapp.send")
                .is_some_and(|rule| rule.allow.is_empty() && rule.deny.is_empty())
        };
        if global_only {
            self.check_at(component, "whatsapp.send", None, now)
        } else {
            frame
        }
    }

    /// The explicit `whatsapp.send` hook at an injected clock, for the tests and for a caller that
    /// already read the time. Unused by the host until `wa:channel/messages` exists (docs/REPLAY.md,
    /// docs/GRANT-POLICY.md "The honest gap"): it is the seam that makes a per-chat limit real, and
    /// taking it away would leave nothing to call when the interface lands.
    #[allow(dead_code)]
    pub fn check_whatsapp_send_at(&self, component: &str, chat: Option<&str>, now: u64) -> Decision {
        self.check_at(component, "whatsapp.send", chat, now)
    }

    /// Count, remember the refusal, and say it on the node's log — never with the target.
    fn count(&self, component: &str, capability: &str, decision: &Decision, now: u64) {
        let bucket = match decision {
            Decision::Allow => &self.counters.allow,
            Decision::Deny(_) => &self.counters.deny,
            Decision::RateLimited { .. } => &self.counters.rate_limited,
            Decision::NeedsApproval(_) => &self.counters.needs_approval,
        };
        bucket.fetch_add(1, Ordering::Relaxed);
        if decision.is_allow() {
            return;
        }
        let reason = decision.reason_str().to_string();
        {
            let mut ring = self.refusals.lock().unwrap_or_else(|e| e.into_inner());
            ring.push_back(Refusal {
                ts_ms: now,
                component: component.chars().take(64).collect(),
                capability: capability.chars().take(64).collect(),
                reason: reason.clone(),
            });
            while ring.len() > REFUSAL_RING {
                ring.pop_front();
            }
        }
        let key = format!("{component}\u{1f}{capability}");
        self.say(&key, &format!("[policy] {component} {capability} -> {decision}"), now);
    }

    /// One log line per key per second: a loop that is refused 10 000 times must not produce 10 000
    /// log lines. The map is bounded so a hostile name space cannot grow it.
    fn say(&self, key: &str, message: &str, now: u64) {
        let speak = {
            let mut logged = self.logged.lock().unwrap_or_else(|e| e.into_inner());
            let last = logged.get(key).copied().unwrap_or(0);
            if now.saturating_sub(last) >= 1000 || now < last {
                if logged.len() < 64 || logged.contains_key(key) {
                    logged.insert(key.to_string(), now);
                }
                true
            } else {
                false
            }
        };
        if speak {
            eprintln!("{message}");
        }
    }

    /// Audit write failures, drained into the node log (sink name only, never a target) and counted
    /// so a silently stopped audit trail is visible (`docs/GRANT-POLICY.md` step 7).
    pub fn tick_at(&self, now: u64) {
        let errors = self.engine().take_audit_errors();
        if !errors.is_empty() {
            let count = errors.len() as u64;
            self.counters.audit_errors.fetch_add(count, Ordering::Relaxed);
            for error in &errors {
                eprintln!("[policy] audit_error: sink {}: {}", error.sink, error.detail);
            }
        }
        let last = self.last_save_ms.load(Ordering::Relaxed);
        if now.saturating_sub(last) >= STATE_SAVE_MS {
            self.last_save_ms.store(now, Ordering::Relaxed);
            if let Err(error) = self.save_state() {
                eprintln!("[policy] state save failed: {error}");
            }
        }
    }

    /// Write the budgets (buckets, daily counters, approvals) next to the policy file.
    pub fn save_state(&self) -> std::io::Result<()> {
        if let Some(parent) = self.paths.state.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let text = self.engine().snapshot_json();
        let tmp = self.paths.state.with_extension("json.tmp");
        std::fs::write(&tmp, text)?;
        std::fs::rename(&tmp, &self.paths.state)
    }

    /// The operator's view: what the policy says, what it has decided, what the audit trail did.
    pub fn status(&self) -> Value {
        let engine = self.engine();
        let snapshot = engine.snapshot();
        let (components, rules) = {
            let policy = engine.policy();
            (policy.components.len(), policy.components.values().map(|c| c.capabilities.len()).sum::<usize>())
        };
        drop(engine);
        let audit = self.audit.lock().unwrap_or_else(|e| e.into_inner());
        let file = audit.file.as_ref().map(|f| json!({"path": f.path().to_string_lossy(), "written": f.written(), "rotations": f.rotations()}));
        let memory = json!({"records": audit.memory.len(), "dropped": audit.memory.dropped()});
        let audit_error = audit.file_error.clone();
        drop(audit);
        let sections_report = self.sections.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let refusals: Vec<Value> = self
            .refusals
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .map(|r| json!({"ts_ms": r.ts_ms, "component": r.component, "capability": r.capability, "reason": r.reason}))
            .collect();
        json!({
            "loaded": self.is_loaded(),
            // "manifest" = no policy file: the manifest grant is the only gate for sensitive
            // capabilities (docs/GRANT-POLICY.md). "policy" = a file is loaded (or was present and
            // is reported in `error`), so an unruled sensitive capability is `no_policy`.
            "mode": self.mode().as_str(),
            // The reload (`docs/KERNEL.md`, "The policy reload"): the sha256 the loaded policy came from,
            // how many times a change was applied, and the last change that was refused. An operator
            // reading this after a deploy can tell "the node has the new policy" from "the node has
            // the old one" without asking the node to restart.
            "reload": {
                "policy_sha256": self.policy_sha256(),
                "applied": self.reloads.load(Ordering::Relaxed),
                "checked_at_ms": self.reload_checked_at_ms.load(Ordering::Relaxed),
                "last": self.last_reload.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|(at, reload)| json!({
                    "at_ms": at,
                    "changed": reload.changed,
                    "applied": reload.applied,
                    "mode": reload.mode.as_str(),
                    "sha256": reload.sha256,
                    "error": reload.error,
                })),
            },
            "policy": {"path": self.paths.policy.to_string_lossy(), "error": self.load_error.lock().unwrap_or_else(|e| e.into_inner()).clone(), "components": components, "rules": rules,
                // The file's other sections: carried (`mesh`, `vault`, `models`, …) and the ones that are
                // unusable, by name. A section error is visible here and in the node's log; the rules
                // above are still in force (docs/GRANT-POLICY.md, "Sections this crate does not read").
                "sections": {
                    "carried": sections_report.carried,
                    "errors": sections_report.errors,
                }},
            "state": {
                "path": self.paths.state.to_string_lossy(),
                "saved_at_ms": snapshot.saved_at_ms,
                "capability_buckets": snapshot.buckets.keys().filter(|k| k.starts_with('g')).count(),
                "target_buckets": snapshot.buckets.keys().filter(|k| k.starts_with('t')).count(),
                "daily_counters": snapshot.daily.len(),
                "pending_approvals": snapshot.approvals.len(),
            },
            "audit": {
                "file": file,
                "error": audit_error,
                "memory": memory,
                // Its own directory, not the node-wide report: one policy answers for one audit
                // trail, and a test's temp paths must not reach a real node's state.
                "usage": crate::store::usage_of_dir(
                    self.paths.audit.parent().unwrap_or_else(|| std::path::Path::new(".")),
                    crate::store::audit_quota(),
                ),
            },
            "decisions": {
                "checks": self.counters.checks.load(Ordering::Relaxed),
                "allow": self.counters.allow.load(Ordering::Relaxed),
                "deny": self.counters.deny.load(Ordering::Relaxed),
                "rate_limited": self.counters.rate_limited.load(Ordering::Relaxed),
                "needs_approval": self.counters.needs_approval.load(Ordering::Relaxed),
                "manifest_mode": self.counters.manifest_mode.load(Ordering::Relaxed),
                "audit_errors": self.counters.audit_errors.load(Ordering::Relaxed),
            },
            "recent_refusals": refusals,
        })
    }
}

fn node() -> &'static NodePolicy {
    static NODE: OnceLock<std::sync::Arc<NodePolicy>> = OnceLock::new();
    let policy = NODE.get_or_init(|| {
        let policy = std::sync::Arc::new(NodePolicy::open(Paths::resolve()));
        // The watcher follows *this* instance (its file, its engine), not a second copy of the
        // node's state; it is started here so that any process that asks the policy a question also
        // follows its file, whatever the caller was.
        NodePolicy::spawn_watcher(&policy);
        policy
    });
    policy
}

/// How often the watcher looks at the file, unless `WA_GRANT_POLICY_WATCH_MS` says otherwise. One
/// stat per period; the hash is only computed when the stat moved. `0` disables the watcher (a node
/// that wants a reload to be an explicit restart).
fn watch_interval() -> Option<std::time::Duration> {
    let ms = std::env::var("WA_GRANT_POLICY_WATCH_MS").ok().and_then(|v| v.trim().parse::<u64>().ok()).unwrap_or(1000);
    (ms > 0).then(|| std::time::Duration::from_millis(ms.clamp(50, 60_000)))
}

/// Reload the node policy now (the explicit form of what the watcher does every second):
/// `host.policy_status` and a test can drive it without waiting for a tick.
pub fn reload() -> Reload {
    node().reload()
}

/// Check one call against the node policy (audited, counted). Call sites map the answer to the
/// guest's error; a refusal never performs the effect.
pub fn check(component: &str, capability: &str, target: Option<&str>) -> Decision {
    node().check_at(component, capability, target, now_ms())
}

/// Record a refusal the caller made before the policy engine was asked (a manifest grant that is
/// absent, an interface this node never serves): one audit record with the caller's reason word.
pub fn record_deny(component: &str, capability: &str, target: Option<&str>, reason: &str) {
    node().record_deny_at(component, capability, target, reason, now_ms())
}

/// `check` that only enforces a rule the policy file actually wrote (wasi-socket path).
pub fn check_if_ruled(component: &str, capability: &str, target: Option<&str>) -> Decision {
    node().check_if_ruled_at(component, capability, target, now_ms())
}

/// The interim opaque-frame send check (global budget only; see `NodePolicy::check_opaque_send_at`).
pub fn check_opaque_send(component: &str, authority: &str) -> Decision {
    node().check_opaque_send_at(component, authority, now_ms())
}

/// The explicit `whatsapp.send` hook: the one check that needs the chat id. Its caller is the
/// explicit send (`crate::whatsapp_send`, `docs/HOST.md`), which names the target `chat:<jid>` and so
/// makes the per-chat and daily limits real; the opaque-frame path (`check_opaque_send`) still
/// charges the global cap for every frame the component writes.
pub fn check_whatsapp_send(component: &str, chat: Option<&str>) -> Decision {
    check(component, "whatsapp.send", chat)
}

/// Periodic work: drain audit errors, save the budgets every five minutes.
pub fn tick() {
    node().tick_at(now_ms())
}

/// `host.policy_status()` -> the JSON from [`NodePolicy::status`].
pub extern "C-unwind" fn capability(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let text = node().status().to_string();
    unsafe {
        wa_host_support::lua::lua_pushlstring(l, text.as_ptr() as *const std::os::raw::c_char, text.len());
    }
    1
}

/// A compact form for `host.telemetry`'s JSON: whether the policy is loaded and what it decided,
/// without the store report it already carries beside it.
pub fn status_summary() -> Value {
    let status = node().status();
    json!({
        "loaded": status["loaded"],
        "mode": status["mode"],
        "policy": status["policy"],
        "decisions": status["decisions"],
        "recent_refusals": status["recent_refusals"],
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_paths(tag: &str) -> Paths {
        let root = std::env::temp_dir().join(format!("wa-policy-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("audit")).unwrap();
        Paths { policy: root.join("policy.json"), state: root.join("state.json"), audit: root.join("audit").join("grant-policy.jsonl") }
    }

    fn test_policy(paths: &Paths, json_text: &str) {
        std::fs::write(&paths.policy, json_text).unwrap();
    }

    #[test]
    fn an_absent_policy_file_is_manifest_mode_not_default_deny() {
        // The upgrade rule (docs/GRANT-POLICY.md, "Manifest mode"): installing a binary that speaks
        // the policy layer must not take capabilities away from a node that never wrote policy.json.
        let paths = temp_paths("absent");
        let policy = NodePolicy::open(paths.clone());
        assert_eq!(policy.mode(), Mode::Manifest);
        assert!(!policy.is_loaded(), "an absent file is reported as not loaded");
        // Sensitive by default, and no rule anywhere: the manifest grant stays the only gate.
        assert_eq!(policy.check_at("wa-whatsapp", "kv.write", Some("ses/a"), 1_000), Decision::Allow);
        assert_eq!(policy.check_at("wa-whatsapp", "credentials.read", Some("WA_TOKEN"), 1_000), Decision::Allow);
        assert_eq!(policy.check_at("wa-whatsapp", "net.dial", Some("web.whatsapp.com:443"), 1_000), Decision::Allow);
        assert_eq!(policy.check_at("wa-whatsapp", "http.request", Some("mmg.whatsapp.net:443"), 1_000), Decision::Allow);
        // Ordinary capabilities (logging, reading the component's own state) are unaffected.
        assert_eq!(policy.check_at("wa-whatsapp", "kv.read", Some("ses/a"), 1_000), Decision::Allow);
        assert_eq!(policy.check_at("wa-whatsapp", "log.write", None, 1_000), Decision::Allow);
        // Counted, and counted as manifest mode rather than as an allow a rule produced.
        let status = policy.status();
        assert_eq!(status["mode"], "manifest");
        assert_eq!(status["decisions"]["checks"], 6);
        assert_eq!(status["decisions"]["manifest_mode"], 6);
        assert_eq!(status["decisions"]["deny"], 0, "manifest mode refuses nothing for want of a rule");
        assert!(status["recent_refusals"].as_array().unwrap().is_empty());
        // Audited as manifest_mode for the sensitive ones, with the target still a digest.
        let trail = std::fs::read_to_string(&paths.audit).unwrap_or_default();
        assert_eq!(trail.matches(MANIFEST_REASON).count(), 4, "four of the six are sensitive by default: {trail}");
        assert!(!trail.contains("ses/a"), "the audit trail never carries the key: {trail}");
        assert!(trail.contains("sha256:"), "targets are digests: {trail}");
        std::fs::remove_dir_all(paths.policy.parent().unwrap()).ok();
    }

    #[test]
    fn a_loaded_policy_file_makes_an_unruled_sensitive_capability_no_policy() {
        // The other half of the same rule: the file's presence is what turns default-deny on, and
        // it applies to the capabilities that have no rule beside the ones that do.
        let paths = temp_paths("modes");
        test_policy(
            &paths,
            r#"{"version":1,"components":{"wa-whatsapp":{"capabilities":{
                 "net.dial":{"allow":["web.whatsapp.com:443"]},
                 "kv.write":{},
                 "credentials.read":{},
                 "http.request":{},
                 "whatsapp.send":{"allow":["chat:self"]}
               }}}}"#,
        );
        let policy = NodePolicy::open(paths.clone());
        assert_eq!(policy.mode(), Mode::Policy);
        assert!(policy.is_loaded());
        assert_eq!(policy.status()["mode"], "policy");
        assert_eq!(policy.check_at("wa-whatsapp", "net.dial", Some("web.whatsapp.com:443"), 1_000), Decision::Allow);
        // A rule with no limits is "any target, no rate": the documented way to keep a capability.
        assert_eq!(policy.check_at("wa-whatsapp", "kv.write", Some("anything/at/all"), 1_000), Decision::Allow);
        // A component the file does not name at all: every sensitive capability is refused.
        assert_eq!(
            policy.check_at("unlisted-component", "net.dial", Some("web.whatsapp.com:443"), 1_000),
            Decision::Deny(wa_grant_policy::Reason::NoPolicy)
        );
        assert_eq!(
            policy.check_at("unlisted-component", "kv.write", Some("k"), 1_000),
            Decision::Deny(wa_grant_policy::Reason::NoPolicy)
        );
        // An ordinary capability in an unlisted component is still allowed: the policy has nothing
        // to say about a kv read.
        assert_eq!(policy.check_at("unlisted-component", "kv.read", Some("k"), 1_000), Decision::Allow);
        let status = policy.status();
        assert_eq!(status["decisions"]["manifest_mode"], 0, "no decision here came from manifest mode");
        assert_eq!(status["decisions"]["deny"], 2);
        std::fs::remove_dir_all(paths.policy.parent().unwrap()).ok();
    }

    /// A refusal the *caller* made before the engine was asked is still evidence: one audit record
    /// with the caller's reason word, counted as a denial, and never a budget charge. This is the path
    /// a manifest gate takes (`docs/WASI-INTERFACES.md`: the manifest answers first, the policy second),
    /// so without it the outline of a component asking for more than it declared would be invisible.
    #[test]
    fn a_refusal_the_caller_made_is_recorded_with_its_own_reason() {
        let paths = temp_paths("caller-deny");
        let policy = NodePolicy::open(paths.clone());
        policy.record_deny_at("svc-wasi-fs", "wasi.filesystem", Some("/data"), "filesystem_root", 1_000);
        policy.record_deny_at("svc-wasi-env", "wasi.import", Some("wasi:tls/certificate@0.1.0"), "interface_never_served", 1_000);
        let status = policy.status();
        assert_eq!(status["decisions"]["deny"], 2, "{status}");
        assert_eq!(status["decisions"]["checks"], 2, "a refusal is a check");
        assert_eq!(status["decisions"]["allow"], 0);
        let refusals = status["recent_refusals"].as_array().unwrap();
        assert_eq!(refusals[0]["capability"], "wasi.filesystem");
        assert_eq!(refusals[0]["reason"], "no_policy", "the decision word stays the crate's; the caller's reason rides in the record");
        let trail = std::fs::read_to_string(&paths.audit).unwrap_or_default();
        assert!(trail.contains("filesystem_root"), "the caller's reason word is on the record: {trail}");
        assert!(trail.contains("interface_never_served"), "{trail}");
        assert!(trail.contains("wasi.import"), "{trail}");
        assert!(!trail.contains("wasi:tls"), "even a refusal digests its target: {trail}");
        std::fs::remove_dir_all(paths.policy.parent().unwrap()).ok();
    }

    #[test]
    fn a_rule_is_enforced_and_refusals_are_visible_without_the_target() {
        let paths = temp_paths("rule");
        test_policy(
            &paths,
            r#"{"version":1,"components":{"wa-whatsapp":{"capabilities":{
                 "whatsapp.send":{"allow":["chat:self"],"rate":{"per_minute":20},"per_target":{"per_minute":6}}
               }}}}"#,
        );
        let policy = NodePolicy::open(paths.clone());
        assert!(policy.is_loaded());
        assert_eq!(policy.check_at("wa-whatsapp", "whatsapp.send", Some("chat:self"), 1_000), Decision::Allow);
        assert_eq!(
            policy.check_at("wa-whatsapp", "whatsapp.send", Some("5511999999999@g.us"), 1_000),
            Decision::Deny(wa_grant_policy::Reason::TargetNotAllowed)
        );
        let status = policy.status();
        assert_eq!(status["decisions"]["allow"], 1);
        assert_eq!(status["decisions"]["deny"], 1);
        let refusal = &status["recent_refusals"][0];
        assert_eq!(refusal["capability"], "whatsapp.send");
        assert_eq!(refusal["reason"], "target_not_allowed");
        assert!(!refusal.to_string().contains("5511999999999"), "a refusal carries no target text: {refusal}");
        // The audit trail is on disk and holds a digest, not the chat id.
        let text = std::fs::read_to_string(&paths.audit).unwrap();
        assert!(text.contains("target_not_allowed"), "{text}");
        assert!(!text.contains("5511999999999"), "the audit file must not carry the chat id");
        assert!(text.contains("sha256:"), "targets are digests: {text}");
        std::fs::remove_dir_all(paths.policy.parent().unwrap()).ok();
    }

    #[test]
    fn a_rate_limit_refuses_after_the_budget_and_survives_a_state_round_trip() {
        let paths = temp_paths("rate");
        test_policy(
            &paths,
            r#"{"version":1,"components":{"wa-whatsapp":{"capabilities":{
                 "net.dial":{"rate":{"per_minute":60,"burst":1},"daily_cap":10}
               }}}}"#,
        );
        let policy = NodePolicy::open(paths.clone());
        // A realistic epoch (the crate refuses a daily counter recorded on day 0, i.e. before
        // 1970-01-02, because that cannot be a real node's clock).
        let now = 1_760_000_000_000u64;
        assert_eq!(policy.check_at("wa-whatsapp", "net.dial", Some("a.example:443"), now), Decision::Allow);
        match policy.check_at("wa-whatsapp", "net.dial", Some("a.example:443"), now) {
            Decision::RateLimited { retry_after_ms, reason } => {
                assert_eq!(reason, wa_grant_policy::Reason::CapabilityRateLimited);
                assert!(retry_after_ms > 0 && retry_after_ms <= 60_000, "{retry_after_ms}");
            }
            other => panic!("expected a rate limit, got {other}"),
        }
        // A refusal charged nothing: one token per second back at 60/min, so a second later it
        // passes and is charged again.
        assert_eq!(policy.check_at("wa-whatsapp", "net.dial", Some("a.example:443"), now + 1_000), Decision::Allow);
        policy.save_state().unwrap();
        let reloaded = NodePolicy::open(paths.clone());
        // The daily counter and the spent bucket came back with the state, so the budget continues
        // instead of resetting on a restart.
        assert_eq!(reloaded.status()["state"]["daily_counters"], 1);
        assert!(matches!(
            reloaded.check_at("wa-whatsapp", "net.dial", Some("a.example:443"), now + 1_500),
            Decision::RateLimited { .. }
        ));
        std::fs::remove_dir_all(paths.policy.parent().unwrap()).ok();
    }

    #[test]
    fn an_unparsable_policy_file_is_reported_and_refuses_sensitive_capabilities() {
        let paths = temp_paths("bad");
        test_policy(&paths, r#"{"version":1,"components":{"x":{"capabilities":{"kv.write":{"per_minutes":1}}}}}"#);
        let policy = NodePolicy::open(paths.clone());
        assert!(!policy.is_loaded());
        // A half-written file is NOT "no file": falling back to manifest mode here would silently
        // remove the limits an operator was in the middle of writing.
        assert_eq!(policy.mode(), Mode::Policy);
        let error = policy.status()["policy"]["error"].as_str().unwrap_or_default().to_string();
        assert!(error.contains("not valid JSON"), "{error}");
        assert_eq!(policy.check_at("x", "kv.write", Some("k"), 1_000), Decision::Deny(wa_grant_policy::Reason::NoPolicy));
        std::fs::remove_dir_all(paths.policy.parent().unwrap()).ok();
    }

    /// The shipped default policy, checked against the calls the components in this tree actually
    /// make. This is the upgrade test with teeth: the deploy installs `policies/default.json` on the
    /// first node that has none (`docs/GRANT-POLICY.md`, "The shipped default"), so it must keep
    /// wa-whatsapp dialling, writing kv, downloading and reading its secret - and it must still
    /// refuse the chats the operator did not allow.
    #[test]
    fn the_shipped_default_policy_keeps_the_components_this_tree_installs_working() {
        let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../policies/default.json");
        PolicySet::parse(&std::fs::read_to_string(&source).expect("policies/default.json is in the tree"))
            .expect("policies/default.json parses as schema 1");
        let paths = temp_paths("default");
        std::fs::copy(&source, &paths.policy).unwrap();
        let policy = NodePolicy::open(paths.clone());
        assert_eq!(policy.mode(), Mode::Policy);
        let now = 1_760_000_000_000u64; // a realistic epoch: the daily counter needs a real UTC day

        // wa-whatsapp: the WhatsApp hosts its manifest grants, both for the socket and for media.
        for addr in ["web.whatsapp.com:443", "g.whatsapp.net:443", "mmg.whatsapp.net:443", "static.whatsapp.net:443"] {
            assert_eq!(policy.check_at("wa-whatsapp", "net.dial", Some(addr), now), Decision::Allow, "net.dial {addr}");
            assert_eq!(policy.check_at("wa-whatsapp", "http.request", Some(addr), now), Decision::Allow, "http.request {addr}");
        }
        // Every key prefix `rust/components/wa-whatsapp/src/store.rs`, `lib.rs` and `guest.rs` (the
        // 0.2 message fence) write. A prefix the component writes but this file does not rule is a
        // capability refused with `no_policy` the moment policy.json is installed.
        for key in ["dev", "id/5511@s.whatsapp.net", "ses/5511@s.whatsapp.net", "pk/17", "spk/3", "sk/5511@s.whatsapp.net", "sync/abcd", "ver/app", "mac/app/abcd", "lid/12", "tc/12", "tx/5511@s.whatsapp.net/ABC", "fence/ABC", "ix/m/5511@lid/07ffffffffffffff/ABC", "ix/w/boleto/07ffffffffffffff/ABC/5511@lid"] {
            assert_eq!(policy.check_at("wa-whatsapp", "kv.write", Some(key), now), Decision::Allow, "kv.write {key}");
        }
        assert_eq!(policy.check_at("wa-whatsapp", "credentials.read", Some("WA_WHATSAPP_TOKEN"), now), Decision::Allow);
        // An explicit requested send may go to any chat - the owner's decision of 06/11 that the new
        // bridge sends ordinary messages freely, like the old connector (`docs/GRANT-POLICY.md`). The
        // target is always the exact JID the caller named, which is what the producer passes now.
        for chat in [
            "chat:5511999999999@s.whatsapp.net",
            "chat:72103978127547@lid",
            "chat:120363000000000001@g.us",
        ] {
            assert_eq!(policy.check_at("wa-whatsapp", "whatsapp.send", Some(chat), now), Decision::Allow, "{chat}");
        }
        // A status/list broadcast and a newsletter are denied outright, and the deny wins over `*`.
        for chat in ["chat:status@broadcast", "chat:120363000000000001@newsletter"] {
            assert_eq!(
                policy.check_at("wa-whatsapp", "whatsapp.send", Some(chat), now),
                Decision::Deny(wa_grant_policy::Reason::TargetDenied),
                "{chat}"
            );
        }
        // Six sends a minute to one chat; the seventh is refused by the per-chat bucket, and the
        // reason says which bucket it was.
        for i in 0..6 {
            assert_eq!(
                policy.check_at("wa-whatsapp", "whatsapp.send", Some("chat:5511888888888@lid"), now),
                Decision::Allow,
                "send {i}"
            );
        }
        assert!(matches!(
            policy.check_at("wa-whatsapp", "whatsapp.send", Some("chat:5511888888888@lid"), now),
            Decision::RateLimited { reason: wa_grant_policy::Reason::TargetRateLimited, .. }
        ));
        // A key this node's store never writes is still refused, and so is a host it never dials.
        assert_eq!(
            policy.check_at("wa-whatsapp", "kv.write", Some("someone-elses/key"), now),
            Decision::Deny(wa_grant_policy::Reason::TargetNotAllowed)
        );
        assert_eq!(
            policy.check_at("wa-whatsapp", "net.dial", Some("evil.example:443"), now),
            Decision::Deny(wa_grant_policy::Reason::TargetNotAllowed)
        );
        // The MCP fixtures reach the connector over loopback and nothing else.
        assert_eq!(policy.check_at("mcp-whatsapp", "net.dial", Some("127.0.0.1:3001"), now), Decision::Allow);
        assert_eq!(
            policy.check_at("mcp-whatsapp", "net.dial", Some("10.0.0.5:3001"), now),
            Decision::Deny(wa_grant_policy::Reason::TargetNotAllowed)
        );
        assert_eq!(policy.check_at("mcp-whatsapp", "credentials.read", Some("WA_MCP_WHATSAPP_TOKEN"), now), Decision::Allow);
        // svc-echo and mcp-echo: the named rules exist, and a component named in the file is never
        // refused for want of a rule. Both component fixtures (0.1 and 0.2) dial loopback, write
        // their own kv namespace and read it back; the 0.2 one goes through `http.send`.
        for fixture in ["svc-echo", "svc-echo-v1"] {
            assert_eq!(policy.check_at(fixture, "net.dial", Some("127.0.0.1:8799"), now), Decision::Allow, "{fixture} net.dial");
            assert_eq!(policy.check_at(fixture, "http.request", Some("127.0.0.1:8799"), now), Decision::Allow, "{fixture} http.request");
            assert_eq!(policy.check_at(fixture, "kv.write", Some("echo/key"), now), Decision::Allow, "{fixture} kv.write");
            assert_eq!(policy.check_at(fixture, "kv.read", Some("echo/key"), now), Decision::Allow, "{fixture} kv.read");
        }
        assert_eq!(policy.check_at("mcp-echo", "kv.read", Some("k"), now), Decision::Allow);
        std::fs::remove_dir_all(paths.policy.parent().unwrap()).ok();
    }

    #[test]
    fn the_interim_send_cap_needs_a_rule_that_names_no_chat() {
        let paths = temp_paths("send");
        test_policy(
            &paths,
            r#"{"version":1,"components":{
                 "global-only":{"capabilities":{"net.send":{"allow":[]},"whatsapp.send":{"rate":{"per_minute":2,"burst":2}}}},
                 "per-chat":{"capabilities":{"whatsapp.send":{"allow":["chat:self"]}}}
               }}"#,
        );
        let policy = NodePolicy::open(paths.clone());
        // A rule with no targets: every outbound frame is charged to the global message budget.
        assert!(policy.check_opaque_send_at("global-only", "web.whatsapp.com:443", 1_000).is_allow());
        assert!(policy.check_opaque_send_at("global-only", "web.whatsapp.com:443", 1_000).is_allow());
        assert!(matches!(
            policy.check_opaque_send_at("global-only", "web.whatsapp.com:443", 1_000),
            Decision::RateLimited { .. }
        ));
        // A rule that names chats is not guessed at from an opaque frame: the frame is not refused.
        assert!(policy.check_opaque_send_at("per-chat", "web.whatsapp.com:443", 1_000).is_allow());
        // The explicit hook with the chat id does enforce the per-chat list.
        assert_eq!(policy.check_whatsapp_send_at("per-chat", Some("chat:other"), 1_000), Decision::Deny(wa_grant_policy::Reason::TargetNotAllowed));
        std::fs::remove_dir_all(paths.policy.parent().unwrap()).ok();
    }

    #[test]
    fn only_a_written_rule_is_enforced_on_the_wasi_socket_path() {
        let paths = temp_paths("ruled");
        test_policy(&paths, r#"{"version":1,"components":{"mcp-whatsapp":{"capabilities":{"net.dial":{"allow":["127.0.0.1:1"]}}}}}"#);
        let policy = NodePolicy::open(paths.clone());
        assert!(policy.check_if_ruled_at("mcp-whatsapp", "net.dial", Some("127.0.0.1:1"), 1_000).is_allow());
        assert!(!policy.check_if_ruled_at("mcp-whatsapp", "net.dial", Some("evil.example:443"), 1_000).is_allow());
        // A component the file does not name is untouched by the policy layer.
        assert!(policy.check_if_ruled_at("mcp-echo", "net.dial", Some("evil.example:443"), 1_000).is_allow());
        std::fs::remove_dir_all(paths.policy.parent().unwrap()).ok();
    }

    /// The 06/11 production bug, first half: the deploy wrote `policy.json` 24 s after the node
    /// started, and the node went on enforcing what it had loaded. A file that appears while the
    /// node runs switches the layer on at the next check of the file.
    #[test]
    fn a_policy_file_that_appears_after_start_is_loaded_without_a_restart() {
        let paths = temp_paths("appears");
        let policy = NodePolicy::open(paths.clone());
        assert_eq!(policy.mode(), Mode::Manifest, "the node started with no policy file");
        assert!(policy.check_at("wa-whatsapp", "whatsapp.send", Some("chat:self"), 1_000).is_allow());
        let unchanged = policy.reload_at(2_000);
        assert!(!unchanged.changed, "nothing on disk moved: {unchanged:?}");
        // The deploy installs the policy.
        test_policy(
            &paths,
            r#"{"version":1,"components":{"wa-whatsapp":{"capabilities":{"whatsapp.send":{"allow":["chat:self"]}}}}}"#,
        );
        let reload = policy.reload_at(3_000);
        assert!(reload.changed && reload.applied, "{reload:?}");
        assert_eq!(reload.mode, Mode::Policy);
        assert_eq!(reload.error, None);
        assert_eq!(policy.mode(), Mode::Policy, "the layer is on now, not at the next start");
        // The rule the operator wrote is enforced from this moment, in both directions.
        assert!(policy.check_at("wa-whatsapp", "whatsapp.send", Some("chat:self"), 4_000).is_allow());
        assert_eq!(
            policy.check_at("wa-whatsapp", "whatsapp.send", Some("5511999999999@g.us"), 4_000),
            Decision::Deny(wa_grant_policy::Reason::TargetNotAllowed)
        );
        assert_eq!(policy.status()["reload"]["applied"], 1);
        assert_eq!(policy.status()["reload"]["policy_sha256"].as_str().unwrap().len(), 64);
        // A second call with the same bytes is not a change (one stat, no re-parse, no log line).
        assert!(!policy.reload_at(5_000).changed);
        std::fs::remove_dir_all(paths.policy.parent().unwrap()).ok();
    }

    /// Second half: a *tightened* policy takes effect for a running node, and budgets carry over so
    /// a reload cannot be used to reset a rate limit.
    #[test]
    fn a_reload_tightens_a_running_node_and_keeps_its_budgets() {
        let paths = temp_paths("tighten");
        let wide = r#"{"version":1,"components":{"wa":{"capabilities":{"whatsapp.send":{"allow":["chat:self"],"rate":{"per_minute":1}}}}}}"#;
        test_policy(&paths, wide);
        let policy = NodePolicy::open(paths.clone());
        assert!(policy.check_at("wa", "whatsapp.send", Some("chat:self"), 1_000).is_allow());
        // The operator replaces the file with a tighter one: the chat is no longer allowed.
        test_policy(&paths, r#"{"version":1,"components":{"wa":{"capabilities":{"whatsapp.send":{"allow":["chat:alerts"]}}}}}"#);
        let reload = policy.reload_at(2_000);
        assert!(reload.applied, "{reload:?}");
        assert_eq!(
            policy.check_at("wa", "whatsapp.send", Some("chat:self"), 2_000),
            Decision::Deny(wa_grant_policy::Reason::TargetNotAllowed),
            "the new file is what is enforced, immediately"
        );
        assert!(policy.check_at("wa", "whatsapp.send", Some("chat:alerts"), 2_000).is_allow());
        std::fs::remove_dir_all(paths.policy.parent().unwrap()).ok();
    }

    /// The watcher itself, not just the reload: a file written *after* the node is running is applied
    /// without anybody asking. This is the fix's second half - the first is the deploy's order
    /// (`scripts/test-deploy-policy-order.sh`).
    ///
    /// One watcher per process (the flag in `spawn_watcher` is global), so this is the only test that
    /// spawns one, and it sets the interval itself.
    #[test]
    fn the_watcher_applies_a_file_written_while_the_node_runs() {
        std::env::set_var("WA_GRANT_POLICY_WATCH_MS", "50");
        let paths = temp_paths("watch");
        let policy = std::sync::Arc::new(NodePolicy::open(paths.clone()));
        assert_eq!(policy.mode(), Mode::Manifest, "nothing on disk at load");
        NodePolicy::spawn_watcher(&policy);
        test_policy(
            &paths,
            r#"{"version":1,"components":{"wa":{"capabilities":{"whatsapp.send":{"allow":["chat:self"]}}}}}"#,
        );
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while std::time::Instant::now() < deadline && policy.mode() == Mode::Manifest {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert_eq!(policy.mode(), Mode::Policy, "the watcher picked the file up on its own");
        assert_eq!(
            policy.check_at("wa", "whatsapp.send", Some("5511999999999@g.us"), 1_000),
            Decision::Deny(wa_grant_policy::Reason::TargetNotAllowed),
            "and the rule it carries is enforced"
        );
        assert_eq!(policy.status()["reload"]["applied"], 1);
        std::fs::remove_dir_all(paths.policy.parent().unwrap()).ok();
    }

    /// A half-written file never replaces a working policy (and never falls back to "no limits"
    /// either), and the failure is visible in the operator's status.
    #[test]
    fn a_broken_or_removed_file_keeps_the_loaded_policy_and_says_why() {
        let paths = temp_paths("broken");
        test_policy(&paths, r#"{"version":1,"components":{"wa":{"capabilities":{"net.dial":{"allow":["a.example:443"]}}}}}"#);
        let policy = NodePolicy::open(paths.clone());
        std::fs::write(&paths.policy, "{\"version\":1,\"components\":{").unwrap();
        let reload = policy.reload_at(2_000);
        assert!(reload.changed);
        assert!(!reload.applied);
        assert!(reload.error.is_some(), "{reload:?}");
        assert_eq!(policy.mode(), Mode::Policy);
        assert!(policy.check_at("wa", "net.dial", Some("a.example:443"), 2_000).is_allow(), "the working policy still decides");
        assert!(!policy.check_at("wa", "net.dial", Some("b.example:443"), 2_000).is_allow());
        assert!(policy.status()["policy"]["error"].as_str().unwrap().contains("json") || policy.status()["policy"]["error"].as_str().is_some());
        // Fixing the file applies it: a broken write is not a restart away.
        test_policy(&paths, r#"{"version":1,"components":{"wa":{"capabilities":{"net.dial":{"allow":["b.example:443"]}}}}}"#);
        let fixed = policy.reload_at(3_000);
        assert!(fixed.applied, "{fixed:?}");
        assert!(policy.check_at("wa", "net.dial", Some("b.example:443"), 3_000).is_allow());
        // Removing the file does NOT widen the node: the loaded policy stays, and that is reported.
        std::fs::remove_file(&paths.policy).unwrap();
        let removed = policy.reload_at(4_000);
        assert!(removed.changed && !removed.applied, "{removed:?}");
        assert!(removed.error.as_deref().unwrap_or_default().contains("policy_removed"), "{removed:?}");
        assert_eq!(policy.mode(), Mode::Policy);
        assert!(!policy.check_at("wa", "net.dial", Some("c.example:443"), 4_000).is_allow(), "still ruled");
        std::fs::remove_dir_all(paths.policy.parent().unwrap()).ok();
    }

    /// The incident of 08/11 03:51–04:10 (openclaw), at the layer the operator met it: a `mesh` section
    /// hand-added to the node's `policy.json` and the component's own rule answered `deny(no_policy)` -
    /// `wa-whatsapp` `net.dial` refused with the rule right there in the file. The whole file was
    /// unreadable (an unknown field is a load error in the engine's schema), so the node ran `Mode::Policy`
    /// with an *empty* policy. Now the section rides along and the rule decides.
    #[test]
    fn the_0811_incident_a_mesh_section_does_not_refuse_the_component_rules() {
        let paths = temp_paths("mesh-section");
        let text = serde_json::json!({
            "version": 1,
            "sensitive_capabilities": [],
            "mesh": {"version": 1, "enabled": true, "roster_key": "a".repeat(64), "roster": "mesh-roster.json"},
            "components": {"wa-whatsapp": {"capabilities": {"net.dial": {
                "allow": ["*.whatsapp.net:443"],
                "rate": {"per_minute": 60, "burst": 120}
            }}}}
        })
        .to_string();
        test_policy(&paths, &text);
        let policy = NodePolicy::open(paths.clone());
        assert_eq!(policy.mode(), Mode::Policy);
        assert!(policy.is_loaded(), "the file loaded: it is the sections that used to break it");
        assert!(policy.check_at("wa-whatsapp", "net.dial", Some("mmg.whatsapp.net:443"), 1_000).is_allow(), "the component's own rule decides");
        assert!(!policy.check_at("wa-whatsapp", "net.dial", Some("elsewhere.example:443"), 1_000).is_allow());
        let status = policy.status();
        assert_eq!(status["policy"]["error"], Value::Null, "no load error: {status}");
        assert_eq!(status["policy"]["sections"]["carried"][0], "mesh", "the section is reported as carried");
        assert!(status["policy"]["sections"]["errors"].as_object().unwrap().is_empty(), "{status}");
        // A rule the operator did *not* write is still refused by default: the section did not open the
        // node up either.
        assert!(!policy.check_at("wa-whatsapp", "credentials.read", Some("WA_WHATSAPP_TOKEN"), 1_100).is_allow());

        // And the loud half: an *invalid* mesh section is named in `policy_status` (and logged), while the
        // rules beside it keep deciding. A broken section must never be a silent drop either.
        let broken = text.replace(r#""enabled":true"#, r#""enabled":true,"port":0"#);
        test_policy(&paths, &broken);
        let reload = policy.reload_at(2_000);
        assert!(reload.applied, "the file parses; only a section is unusable: {reload:?}");
        assert!(policy.check_at("wa-whatsapp", "net.dial", Some("mmg.whatsapp.net:443"), 2_000).is_allow(), "the rules are still in force");
        let status = policy.status();
        let error = status["policy"]["sections"]["errors"]["mesh"].as_str().unwrap_or_default().to_string();
        assert!(error.contains("port"), "the section error is reported by name: {status}");
        std::fs::remove_dir_all(paths.policy.parent().unwrap()).ok();
    }
}
