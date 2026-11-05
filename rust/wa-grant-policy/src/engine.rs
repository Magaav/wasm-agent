//! The engine: one stateful object per node that answers `check` / `enforce` and owns the budgets.
//!
//! Evaluation order (documented because it decides which reason a caller sees, and because a
//! refusal must never consume budget):
//!
//! 1. rule lookup — no rule + sensitive capability → `Deny(no_policy)` (default deny);
//!    no rule + ordinary capability → `Allow` (nothing to charge);
//! 2. `effect: "deny"` → `Deny(policy_denied)`;
//! 3. `deny` patterns → `Deny(target_denied)` — deny is checked before allow, so a target that
//!    matches both lists is refused;
//! 4. `allow` patterns → `Deny(target_not_allowed)` when the list is non-empty and nothing matches,
//!    including the case of a call with no target at all;
//! 5. `require_approval` without a valid approval → `NeedsApproval(approval_required)`;
//! 6. `daily_cap` → `RateLimited(daily_cap_reached)` with the wait until the next UTC day;
//! 7. capability-wide bucket (unless the target is exempt) → `RateLimited(capability_rate_limited)`;
//! 8. per-target bucket (from `per_target`, overridden by the first matching `target_rates` entry)
//!    → `RateLimited(target_rate_limited)`; then `Allow`.
//!
//! Budget is charged only when the answer is `Allow`, in the same call, after any audit write.
use crate::audit::{digest_hex, render_target, AuditError, AuditRecord, AuditSink, TargetMode};
use crate::bucket::{day_of, ms_until_next_day, Bucket, DailyCounter};
use crate::decision::{Decision, Reason};
use crate::policy::{Effect, PolicyError, PolicySet, RateLimit};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Separator inside state keys; policy validation forbids it in component and capability names.
const SEP: char = '\u{1f}';

/// Schema of a [`StateSnapshot`].
pub const STATE_SCHEMA: u32 = 1;

/// Default cap on per-target buckets. A per-target bucket belongs to one concrete target (one chat,
/// one authority), so an unbounded map is a memory leak with a hostile target space. The cap only
/// ever applies to per-target buckets; the capability-wide buckets are never evicted.
pub const DEFAULT_MAX_TARGET_BUCKETS: usize = 4_096;

/// Why a snapshot was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateError(pub String);

impl std::fmt::Display for StateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "invalid grant-policy state: {}", self.0)
    }
}

impl std::error::Error for StateError {}

/// An approval a person granted: `uses` calls of this capability/target before `expires_ms`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApprovalState {
    pub uses: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_ms: Option<u64>,
}

impl ApprovalState {
    fn valid_at(&self, now_ms: u64) -> bool {
        self.uses > 0 && self.expires_ms.map(|expires| now_ms < expires).unwrap_or(true)
    }
}

/// In-memory budgets, serialisable: everything needed to continue with the same limits after a
/// restart. Bucket keys are digests, so a snapshot never contains a target id.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StateSnapshot {
    pub schema: u32,
    /// Engine clock at snapshot time (epoch ms), for the operator and for skew checks.
    pub saved_at_ms: u64,
    /// `g<sep>component<sep>capability` (capability-wide) or
    /// `t<sep>component<sep>capability<sep><target digest>` (per target).
    #[serde(default)]
    pub buckets: BTreeMap<String, Bucket>,
    /// `d<sep>component<sep>capability` → today's count.
    #[serde(default)]
    pub daily: BTreeMap<String, DailyCounter>,
    /// `<sep>`-keys of pending approvals, in the same shape `approve` writes.
    #[serde(default)]
    pub approvals: BTreeMap<String, ApprovalState>,
}

#[derive(Debug, Clone, Copy)]
struct Entry {
    bucket: Bucket,
    touched: u64,
}

#[derive(Debug, Clone)]
struct Charge {
    key: String,
    kind: ChargeKind,
}

#[derive(Debug, Clone, Copy)]
enum ChargeKind {
    Bucket(RateLimit),
    Daily,
    Approval,
}

struct Plan {
    decision: Decision,
    charges: Vec<Charge>,
}

/// The policy check, its budgets and its audit error log.
#[derive(Debug, Clone)]
pub struct Engine {
    policy: PolicySet,
    target_mode: TargetMode,
    fail_closed_on_audit: bool,
    max_target_buckets: usize,
    buckets: BTreeMap<String, Entry>,
    daily: BTreeMap<String, DailyCounter>,
    approvals: BTreeMap<String, ApprovalState>,
    tick: u64,
    last_now_ms: u64,
    audit_errors: Vec<AuditError>,
}

impl Engine {
    pub fn new(policy: PolicySet) -> Engine {
        Engine {
            policy,
            target_mode: TargetMode::Digest,
            fail_closed_on_audit: true,
            max_target_buckets: DEFAULT_MAX_TARGET_BUCKETS,
            buckets: BTreeMap::new(),
            daily: BTreeMap::new(),
            approvals: BTreeMap::new(),
            tick: 0,
            last_now_ms: 0,
            audit_errors: Vec::new(),
        }
    }

    /// Replace the policy (a reload). Budgets stay; a bucket above the new capacity is clamped the
    /// next time it is used, so a tightened limit takes effect immediately.
    pub fn set_policy(&mut self, policy: PolicySet) -> Result<(), PolicyError> {
        policy.validate()?;
        self.policy = policy;
        Ok(())
    }

    pub fn policy(&self) -> &PolicySet {
        &self.policy
    }

    /// How audited records name their target.
    pub fn target_mode(&self) -> TargetMode {
        self.target_mode
    }

    pub fn set_target_mode(&mut self, mode: TargetMode) {
        self.target_mode = mode;
    }

    /// With `true` (the default) a sensitive call whose audit write fails is refused with
    /// `deny(audit_unavailable)` instead of proceeding unaudited.
    pub fn fail_closed_on_audit(&self) -> bool {
        self.fail_closed_on_audit
    }

    pub fn set_fail_closed_on_audit(&mut self, on: bool) {
        self.fail_closed_on_audit = on;
    }

    pub fn max_target_buckets(&self) -> usize {
        self.max_target_buckets
    }

    pub fn set_max_target_buckets(&mut self, max: usize) {
        self.max_target_buckets = max.max(1);
        self.evict_targets();
    }

    /// Check and charge. Deterministic for a given policy, state and `now_ms`.
    pub fn check(
        &mut self,
        component: &str,
        capability: &str,
        target: Option<&str>,
        now_ms: u64,
    ) -> Decision {
        self.advance(now_ms);
        let plan = self.plan(component, capability, target, now_ms);
        if plan.decision.is_allow() {
            self.commit(&plan.charges, now_ms);
        }
        plan.decision
    }

    /// A dry run: the same answer `check` would give, without touching the budgets. Useful for a
    /// guest that wants to know `retry_after` before it tries, and for operator tooling.
    pub fn peek(
        &self,
        component: &str,
        capability: &str,
        target: Option<&str>,
        now_ms: u64,
    ) -> Decision {
        self.plan(component, capability, target, now_ms).decision
    }

    /// Check, audit, then charge. Every sensitive capability is recorded (allow included), and so
    /// is every non-allow answer for any capability. If the sink fails the error is kept in
    /// [`Engine::audit_errors`] and, for a sensitive call, the answer becomes
    /// `Deny(audit_unavailable)` unless [`Engine::set_fail_closed_on_audit`] turned that off.
    pub fn enforce(
        &mut self,
        component: &str,
        capability: &str,
        target: Option<&str>,
        now_ms: u64,
        sink: &mut dyn AuditSink,
    ) -> Decision {
        self.advance(now_ms);
        let plan = self.plan(component, capability, target, now_ms);
        let mut decision = plan.decision;
        let sensitive = self.policy.is_audited(component, capability);
        if sensitive || !decision.is_allow() {
            let record =
                AuditRecord::new(now_ms, component, capability, target, &decision, self.target_mode);
            if let Err(error) = sink.write(&record) {
                self.audit_errors.push(error);
                if sensitive && self.fail_closed_on_audit {
                    decision = Decision::Deny(Reason::AuditUnavailable);
                }
            }
        }
        if decision.is_allow() {
            self.commit(&plan.charges, now_ms);
        }
        decision
    }

    /// Grant one approval use for a component/capability, restricted to `target` when given
    /// (`None` covers any target of that capability). `ttl_ms` of `None` means "until used", which
    /// the operator owns; a bounded ttl is the safer default for a UI.
    pub fn approve(
        &mut self,
        component: &str,
        capability: &str,
        target: Option<&str>,
        now_ms: u64,
        ttl_ms: Option<u64>,
    ) -> ApprovalState {
        let key = approval_key(component, capability, target);
        let entry = self.approvals.entry(key).or_insert(ApprovalState { uses: 0, expires_ms: None });
        entry.uses = entry.uses.saturating_add(1);
        entry.expires_ms = ttl_ms.map(|ttl| now_ms.saturating_add(ttl));
        *entry
    }

    /// Drop every approval for this component/capability, target-specific and capability-wide.
    pub fn revoke_approvals(&mut self, component: &str, capability: &str) {
        let prefix = format!("a{SEP}{component}{SEP}{capability}{SEP}");
        self.approvals.retain(|key, _| !key.starts_with(&prefix));
    }

    pub fn pending_approvals(&self, now_ms: u64) -> impl Iterator<Item = (&String, &ApprovalState)> {
        self.approvals.iter().filter(move |(_, state)| state.valid_at(now_ms))
    }

    /// Copy of the budgets. The engine keeps running; a snapshot is a value, not a borrow.
    pub fn snapshot(&self) -> StateSnapshot {
        StateSnapshot {
            schema: STATE_SCHEMA,
            saved_at_ms: self.last_now_ms,
            buckets: self.buckets.iter().map(|(key, entry)| (key.clone(), entry.bucket)).collect(),
            daily: self.daily.clone(),
            approvals: self.approvals.clone(),
        }
    }

    /// Serialise a snapshot as JSON text (`docs/GRANT-POLICY.md` shows it).
    pub fn snapshot_json(&self) -> String {
        serde_json::to_string(&self.snapshot()).expect("snapshot is serialisable")
    }

    /// Replace the budgets with a snapshot. The policy is untouched; a snapshot from another
    /// installation is applied as-is, which is why the schema is checked and the shape validated.
    pub fn restore(&mut self, snapshot: StateSnapshot) -> Result<(), StateError> {
        if snapshot.schema != STATE_SCHEMA {
            return Err(StateError(format!(
                "schema {} (this build speaks {STATE_SCHEMA})",
                snapshot.schema
            )));
        }
        if snapshot.buckets.len() > self.max_target_buckets.saturating_mul(2).max(64) {
            return Err(StateError(format!("{} buckets is more than this engine keeps", snapshot.buckets.len())));
        }
        let mut buckets = BTreeMap::new();
        let mut tick = 0u64;
        for (key, bucket) in snapshot.buckets {
            if !(key.starts_with(&format!("g{SEP}")) || key.starts_with(&format!("t{SEP}"))) {
                return Err(StateError(format!("unexpected bucket key {key:?}")));
            }
            tick += 1;
            buckets.insert(key, Entry { bucket, touched: tick });
        }
        for (key, counter) in &snapshot.daily {
            if !key.starts_with(&format!("d{SEP}")) {
                return Err(StateError(format!("unexpected daily key {key:?}")));
            }
            if counter.day == 0 && counter.count > 0 {
                return Err(StateError(format!("daily key {key:?} has a count on day 0")));
            }
        }
        for key in snapshot.approvals.keys() {
            if !key.starts_with(&format!("a{SEP}")) {
                return Err(StateError(format!("unexpected approval key {key:?}")));
            }
        }
        self.buckets = buckets;
        self.daily = snapshot.daily;
        self.approvals = snapshot.approvals;
        self.tick = tick;
        self.last_now_ms = self.last_now_ms.max(snapshot.saved_at_ms);
        self.evict_targets();
        Ok(())
    }

    pub fn restore_json(&mut self, text: &str) -> Result<(), StateError> {
        let snapshot: StateSnapshot =
            serde_json::from_str(text).map_err(|e| StateError(format!("not valid JSON: {e}")))?;
        self.restore(snapshot)
    }

    /// Forget every bucket, counter and approval (an operator "reset").
    pub fn clear_state(&mut self) {
        self.buckets.clear();
        self.daily.clear();
        self.approvals.clear();
        self.tick = 0;
    }

    /// Audit write failures, oldest first. The host drains this into its own log; an empty vector
    /// is the only state in which "everything sensitive was audited" is true.
    pub fn audit_errors(&self) -> &[AuditError] {
        &self.audit_errors
    }

    pub fn take_audit_errors(&mut self) -> Vec<AuditError> {
        std::mem::take(&mut self.audit_errors)
    }

    /// Live per-target buckets (for a metrics line, and to assert the bound in tests).
    pub fn target_bucket_count(&self) -> usize {
        self.buckets.keys().filter(|key| key.starts_with(&format!("t{SEP}"))).count()
    }

    pub fn capability_bucket_count(&self) -> usize {
        self.buckets.keys().filter(|key| key.starts_with(&format!("g{SEP}"))).count()
    }

    fn advance(&mut self, now_ms: u64) {
        if now_ms > self.last_now_ms {
            self.last_now_ms = now_ms;
        }
    }

    fn plan(&self, component: &str, capability: &str, target: Option<&str>, now_ms: u64) -> Plan {
        let mut charges = Vec::new();
        let deny = |reason| Plan { decision: Decision::Deny(reason), charges: Vec::new() };
        let Some(rule) = self.policy.rule(component, capability) else {
            return if self.policy.is_sensitive(component, capability) {
                deny(Reason::NoPolicy)
            } else {
                Plan { decision: Decision::Allow, charges }
            };
        };
        if rule.effect == Effect::Deny {
            return deny(Reason::PolicyDenied);
        }
        if let Some(target) = target {
            if rule.deny.iter().any(|pattern| pattern.matches(target)) {
                return deny(Reason::TargetDenied);
            }
        }
        if !rule.allow.is_empty() && !target.map(|t| rule.allow.iter().any(|p| p.matches(t))).unwrap_or(false)
        {
            return deny(Reason::TargetNotAllowed);
        }
        if rule.require_approval {
            let specific = approval_key(component, capability, target);
            let wide = approval_key(component, capability, None);
            let used = if self.approvals.get(&specific).map(|a| a.valid_at(now_ms)).unwrap_or(false) {
                specific
            } else if target.is_some() && self.approvals.get(&wide).map(|a| a.valid_at(now_ms)).unwrap_or(false)
            {
                wide
            } else {
                return Plan {
                    decision: Decision::NeedsApproval(Reason::ApprovalRequired),
                    charges: Vec::new(),
                };
            };
            charges.push(Charge { key: used, kind: ChargeKind::Approval });
        }
        if let Some(cap) = rule.daily_cap {
            let key = daily_key(component, capability);
            let count = self.daily.get(&key).map(|c| c.count_on(now_ms)).unwrap_or(0);
            if count >= cap {
                return Plan {
                    decision: Decision::RateLimited {
                        retry_after_ms: ms_until_next_day(now_ms),
                        reason: Reason::DailyCapReached,
                    },
                    charges: Vec::new(),
                };
            }
            charges.push(Charge { key, kind: ChargeKind::Daily });
        }
        let override_ = target.and_then(|t| rule.target_rates.iter().find(|tr| tr.pattern.matches(t)));
        let exempt_global = override_.map(|o| o.exempt_from_global).unwrap_or(false);
        if let Some(rate) = rule.rate {
            if !exempt_global {
                let key = capability_key(component, capability);
                let limited = self.limited(&key, &rate, now_ms);
                if let Some(retry_after_ms) = limited {
                    return Plan {
                        decision: Decision::RateLimited {
                            retry_after_ms,
                            reason: Reason::CapabilityRateLimited,
                        },
                        charges: Vec::new(),
                    };
                }
                charges.push(Charge { key, kind: ChargeKind::Bucket(rate) });
            }
        }
        let per_target = match override_ {
            Some(override_) => Some(override_.limit()),
            None => rule.per_target,
        };
        if let (Some(rate), Some(target)) = (per_target, target) {
            let key = target_key(component, capability, target);
            if let Some(retry_after_ms) = self.limited(&key, &rate, now_ms) {
                return Plan {
                    decision: Decision::RateLimited { retry_after_ms, reason: Reason::TargetRateLimited },
                    charges: Vec::new(),
                };
            }
            charges.push(Charge { key, kind: ChargeKind::Bucket(rate) });
        }
        Plan { decision: Decision::Allow, charges }
    }

    /// `Some(retry_after_ms)` when no token is available at `now_ms`.
    fn limited(&self, key: &str, rate: &RateLimit, now_ms: u64) -> Option<u64> {
        match self.buckets.get(key) {
            None => None,
            Some(entry) if entry.bucket.tokens(rate, now_ms) > 0 => None,
            Some(entry) => Some(entry.bucket.retry_after_ms(rate, now_ms)),
        }
    }

    fn commit(&mut self, charges: &[Charge], now_ms: u64) {
        for charge in charges {
            match charge.kind {
                ChargeKind::Bucket(rate) => {
                    let tick = self.bump_tick();
                    let entry = self
                        .buckets
                        .entry(charge.key.clone())
                        .or_insert(Entry { bucket: Bucket::full(&rate, now_ms), touched: tick });
                    entry.touched = tick;
                    // `plan` proved a token is there and nothing can spend it in between: the
                    // engine is not shared across threads, and `now_ms` is the same reading.
                    let _ = entry.bucket.take(&rate, now_ms);
                }
                ChargeKind::Daily => {
                    self.daily
                        .entry(charge.key.clone())
                        .or_insert(DailyCounter::new(day_of(now_ms)))
                        .bump(now_ms);
                }
                ChargeKind::Approval => {
                    if let Some(state) = self.approvals.get_mut(&charge.key) {
                        state.uses = state.uses.saturating_sub(1);
                    }
                }
            }
        }
        self.approvals.retain(|_, state| state.uses > 0 && state.expires_ms.map(|e| now_ms < e).unwrap_or(true));
        self.evict_targets();
    }

    fn bump_tick(&mut self) -> u64 {
        self.tick += 1;
        self.tick
    }

    /// Keep the per-target map bounded: drop the least recently used per-target buckets. Eviction
    /// is fail-open for that one target only — the capability-wide bucket still bounds the total —
    /// and it can never remove a capability-wide bucket or a daily counter.
    fn evict_targets(&mut self) {
        let target_prefix = format!("t{SEP}");
        let mut targets: Vec<(String, u64)> = self
            .buckets
            .iter()
            .filter(|(key, _)| key.starts_with(&target_prefix))
            .map(|(key, entry)| (key.clone(), entry.touched))
            .collect();
        if targets.len() <= self.max_target_buckets {
            return;
        }
        targets.sort_by_key(|(_, touched)| *touched);
        let drop_count = targets.len() - self.max_target_buckets;
        for (key, _) in targets.into_iter().take(drop_count) {
            self.buckets.remove(&key);
        }
    }
}

fn capability_key(component: &str, capability: &str) -> String {
    format!("g{SEP}{component}{SEP}{capability}")
}

fn target_key(component: &str, capability: &str, target: &str) -> String {
    format!("t{SEP}{component}{SEP}{capability}{SEP}{}", digest_hex(target))
}

fn daily_key(component: &str, capability: &str) -> String {
    format!("d{SEP}{component}{SEP}{capability}")
}

fn approval_key(component: &str, capability: &str, target: Option<&str>) -> String {
    match target {
        Some(target) => {
            format!("a{SEP}{component}{SEP}{capability}{SEP}{}", digest_hex(target))
        }
        None => format!("a{SEP}{component}{SEP}{capability}{SEP}*"),
    }
}

/// Convenience for callers that only have a decision to log: the audited form of a target.
pub fn audit_target(mode: TargetMode, target: &str) -> String {
    render_target(mode, target)
}
