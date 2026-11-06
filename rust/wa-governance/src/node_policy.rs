//! The node's grant policy, wired (docs/GRANT-POLICY.md "How the host wires it").
//!
//! One [`Engine`] and one pair of sinks per node: the durable JSONL audit trail in the bounded
//! `<state>/audit/` directory and a 512-record ring the operator view can read. Every sensitive
//! host call asks this module before it does anything; the answer is the crate's [`Decision`], and
//! the call sites are where a `Deny` becomes a `refused` error for the guest.
//!
//! Loaded once, lazily, on the first check or the first `host.policy_status`:
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
use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
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
    mode: Mode,
    /// A policy file parsed. `false` also for a file that is present but broken - read `mode` for
    /// "is the policy layer on at all".
    loaded: bool,
    load_error: Option<String>,
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
        let (policy, mode, loaded, load_error) = match std::fs::read(&paths.policy) {
            Ok(bytes) => match PolicySet::parse(&String::from_utf8_lossy(&bytes)) {
                Ok(policy) => (policy, Mode::Policy, true, None),
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
            mode,
            loaded,
            load_error,
            last_save_ms: AtomicU64::new(0),
        }
    }

    /// Which gate decides an unruled sensitive capability on this node (`Mode::Manifest` until a
    /// policy file is written).
    pub fn mode(&self) -> Mode {
        self.mode
    }

    fn engine(&self) -> MutexGuard<'_, Engine> {
        self.engine.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Check one sensitive call and audit it. The budget is charged only on `Allow`.
    ///
    /// In [`Mode::Manifest`] the answer is `Allow` - the manifest grant, which the caller has already
    /// applied, is the only gate - and the call is still counted (`decisions.manifest_mode`) and, for
    /// a capability that is sensitive by default, audited with reason [`MANIFEST_REASON`].
    pub fn check_at(&self, component: &str, capability: &str, target: Option<&str>, now: u64) -> Decision {
        self.counters.checks.fetch_add(1, Ordering::Relaxed);
        if self.mode == Mode::Manifest {
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
        let refusals: Vec<Value> = self
            .refusals
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .map(|r| json!({"ts_ms": r.ts_ms, "component": r.component, "capability": r.capability, "reason": r.reason}))
            .collect();
        json!({
            "loaded": self.loaded,
            // "manifest" = no policy file: the manifest grant is the only gate for sensitive
            // capabilities (docs/GRANT-POLICY.md). "policy" = a file is loaded (or was present and
            // is reported in `error`), so an unruled sensitive capability is `no_policy`.
            "mode": self.mode().as_str(),
            "policy": {"path": self.paths.policy.to_string_lossy(), "error": self.load_error, "components": components, "rules": rules},
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
    static NODE: OnceLock<NodePolicy> = OnceLock::new();
    NODE.get_or_init(|| NodePolicy::open(Paths::resolve()))
}

/// Check one call against the node policy (audited, counted). Call sites map the answer to the
/// guest's error; a refusal never performs the effect.
pub fn check(component: &str, capability: &str, target: Option<&str>) -> Decision {
    node().check_at(component, capability, target, now_ms())
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
        assert!(!policy.loaded, "an absent file is reported as not loaded");
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
        assert!(policy.loaded);
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
        assert!(policy.loaded);
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
        assert!(!policy.loaded);
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
        for key in ["dev", "id/5511@s.whatsapp.net", "ses/5511@s.whatsapp.net", "pk/17", "spk/3", "sk/5511@s.whatsapp.net", "sync/abcd", "ver/app", "mac/app/abcd", "lid/12", "tc/12", "tx/5511@s.whatsapp.net/ABC", "fence/ABC"] {
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
}
