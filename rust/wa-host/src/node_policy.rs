//! The node's grant policy, wired (docs/GRANT-POLICY.md "How the host wires it").
//!
//! One [`Engine`] and one pair of sinks per node: the durable JSONL audit trail in the bounded
//! `<state>/audit/` directory and a 512-record ring the operator view can read. Every sensitive
//! host call asks this module before it does anything; the answer is the crate's [`Decision`], and
//! the call sites are where a `Deny` becomes a `refused` error for the guest.
//!
//! Loaded once, lazily, on the first check or the first `host.policy_status`:
//!
//! * `WA_GRANT_POLICY` (else `<state>/policy.json`) — an absent file is an **empty** policy, which
//!   the crate defines as "permissive for ordinary capabilities, default-deny for sensitive ones"
//!   (`credentials.read`, `net.dial`, `http.request`, `whatsapp.send`, `exec.run`, `kv.write`).
//! * a file that does not parse is the same empty policy plus one line on the node's log: the node
//!   starts, the capabilities the policy governs are refused with `no_policy`, and the error is
//!   visible in `host.policy_status` instead of being guessed at.
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
    AuditError, AuditRecord, AuditSink, Decision, Engine, FileAudit, MemoryAudit, PolicySet,
};

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
    loaded: bool,
    load_error: Option<String>,
    last_save_ms: AtomicU64,
}

impl NodePolicy {
    /// Load the policy file and restore the budgets. Never fails: a policy that cannot be read is
    /// reported and behaves as an empty one.
    pub fn open(paths: Paths) -> NodePolicy {
        let (policy, loaded, load_error) = match std::fs::read(&paths.policy) {
            Ok(bytes) => match PolicySet::parse(&String::from_utf8_lossy(&bytes)) {
                Ok(policy) => (policy, true, None),
                Err(error) => {
                    eprintln!("[policy] {}: {error}", paths.policy.display());
                    (PolicySet::empty(), false, Some(error.to_string()))
                }
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (PolicySet::empty(), false, None),
            Err(error) => {
                eprintln!("[policy] {}: {error}", paths.policy.display());
                (PolicySet::empty(), false, Some(format!("{}: {error}", paths.policy.display())))
            }
        };
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
            loaded,
            load_error,
            last_save_ms: AtomicU64::new(0),
        }
    }

    fn engine(&self) -> MutexGuard<'_, Engine> {
        self.engine.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Check one sensitive call and audit it. The budget is charged only on `Allow`.
    pub fn check_at(&self, component: &str, capability: &str, target: Option<&str>, now: u64) -> Decision {
        self.counters.checks.fetch_add(1, Ordering::Relaxed);
        let decision = {
            let mut engine = self.engine();
            let mut audit = self.audit.lock().unwrap_or_else(|e| e.into_inner());
            engine.enforce(component, capability, target, now, &mut *audit)
        };
        self.count(component, capability, &decision, now);
        decision
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
        let speak = {
            let mut logged = self.logged.lock().unwrap_or_else(|e| e.into_inner());
            let last = logged.get(&key).copied().unwrap_or(0);
            if now.saturating_sub(last) >= 1000 || now < last {
                if logged.len() < 64 || logged.contains_key(&key) {
                    logged.insert(key, now);
                }
                true
            } else {
                false
            }
        };
        if speak {
            eprintln!("[policy] {component} {capability} -> {decision}");
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

/// The explicit `whatsapp.send` hook: the one check that needs the chat id, ready for
/// `wa:channel/messages` (`docs/GRANT-POLICY.md`). A guest that can name the chat calls it here and
/// the per-chat limits are real; until that interface exists only the global cap is enforced
/// (`check_opaque_send`), so this is deliberate API with no caller yet.
#[allow(dead_code)]
pub fn check_whatsapp_send(component: &str, chat: Option<&str>) -> Decision {
    check(component, "whatsapp.send", chat)
}

/// Periodic work: drain audit errors, save the budgets every five minutes.
pub fn tick() {
    node().tick_at(now_ms())
}

/// `host.policy_status()` -> the JSON from [`NodePolicy::status`].
pub extern "C-unwind" fn capability(l: *mut crate::lua::LuaState) -> std::os::raw::c_int {
    let text = node().status().to_string();
    unsafe {
        crate::lua::lua_pushlstring(l, text.as_ptr() as *const std::os::raw::c_char, text.len());
    }
    1
}

/// A compact form for `host.telemetry`'s JSON: whether the policy is loaded and what it decided,
/// without the store report it already carries beside it.
pub fn status_summary() -> Value {
    let status = node().status();
    json!({
        "loaded": status["loaded"],
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
    fn an_absent_policy_file_is_default_deny_only_for_sensitive_capabilities() {
        let paths = temp_paths("absent");
        let policy = NodePolicy::open(paths.clone());
        assert!(!policy.loaded, "an absent file is reported as not loaded");
        // Sensitive by default: no rule means no.
        assert_eq!(policy.check_at("wa-whatsapp", "kv.write", Some("session/a"), 1_000), Decision::Deny(wa_grant_policy::Reason::NoPolicy));
        assert_eq!(policy.check_at("wa-whatsapp", "credentials.read", Some("WA_TOKEN"), 1_000), Decision::Deny(wa_grant_policy::Reason::NoPolicy));
        assert_eq!(policy.check_at("wa-whatsapp", "net.dial", Some("web.whatsapp.com:443"), 1_000), Decision::Deny(wa_grant_policy::Reason::NoPolicy));
        // Ordinary capabilities (logging, reading the component's own state) are unaffected.
        assert_eq!(policy.check_at("wa-whatsapp", "kv.read", Some("session/a"), 1_000), Decision::Allow);
        assert_eq!(policy.check_at("wa-whatsapp", "log.write", None, 1_000), Decision::Allow);
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
    fn an_unparsable_policy_file_is_reported_and_behaves_as_an_empty_one() {
        let paths = temp_paths("bad");
        test_policy(&paths, r#"{"version":1,"components":{"x":{"capabilities":{"kv.write":{"per_minutes":1}}}}}"#);
        let policy = NodePolicy::open(paths.clone());
        assert!(!policy.loaded);
        let error = policy.status()["policy"]["error"].as_str().unwrap_or_default().to_string();
        assert!(error.contains("not valid JSON"), "{error}");
        assert_eq!(policy.check_at("x", "kv.write", Some("k"), 1_000), Decision::Deny(wa_grant_policy::Reason::NoPolicy));
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
