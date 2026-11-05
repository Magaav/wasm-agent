//! Behaviour tests for the whole crate: what a policy file means, what a check answers, what the
//! audit trail holds, and what survives a snapshot. Every test uses an injected clock, so every
//! number below is exact.
use crate::audit::{AuditError, AuditRecord, MemoryAudit, TargetMode};
use crate::bucket::DAY_MS;
use crate::*;

const T0: u64 = 1_760_000_000_000;

fn engine(json: &str) -> Engine {
    Engine::new(PolicySet::parse(json).expect("policy"))
}

/// The shipped example policy (the one `docs/GRANT-POLICY.md` documents).
fn whatsapp() -> Engine {
    Engine::new(PolicySet::parse(WHATSAPP_POLICY).expect("example policy"))
}

const WHATSAPP_POLICY: &str = include_str!("../examples/whatsapp-policy.json");

#[test]
fn shipped_example_parses_and_says_what_the_doc_says() {
    let set = PolicySet::parse(WHATSAPP_POLICY).expect("parses");
    let send = set.rule("wa-whatsapp", "whatsapp.send").expect("rule");
    assert_eq!(send.rate.unwrap().capacity(), 20, "20 messages/min global");
    assert_eq!(send.per_target.unwrap().capacity(), 6, "6/min per chat");
    assert_eq!(send.target_rates[0].limit().capacity(), 1, "alerts: 1/min");
    assert!(send.target_rates[0].exempt_from_global);
    assert_eq!(send.daily_cap, Some(200));
    assert!(send.allow.iter().any(|p| p.matches("chat:self")));
    assert!(send.deny.iter().all(|p| !p.matches("5511999999999@g.us")));
    assert!(set.is_sensitive("wa-whatsapp", "whatsapp.send"));
    assert!(set.is_sensitive("wa-whatsapp", "net.dial"));
    assert!(!set.is_sensitive("wa-whatsapp", "log.write"));
}

#[test]
fn a_sensitive_capability_without_a_rule_is_denied_and_an_ordinary_one_is_not() {
    let mut e = whatsapp();
    assert_eq!(
        e.check("wa-whatsapp", "exec.run", Some("sh"), T0),
        Decision::Deny(Reason::NoPolicy)
    );
    assert_eq!(
        e.check("wa-whatsapp", "kv.read", Some("journal/x"), T0),
        Decision::Allow
    );
    // no policy for the component at all: same rule, decided by sensitivity alone
    assert_eq!(
        e.check("wa-telegram", "whatsapp.send", Some("chat:self"), T0),
        Decision::Deny(Reason::NoPolicy)
    );
    assert_eq!(e.check("wa-telegram", "log.write", None, T0), Decision::Allow);
    // an empty policy still refuses secrets
    let mut empty = Engine::new(PolicySet::empty());
    assert_eq!(
        empty.check("c", "credentials.read", Some("TOKEN"), T0),
        Decision::Deny(Reason::NoPolicy)
    );
}

#[test]
fn deny_wins_over_allow_and_effect_deny_refuses_everything() {
    let mut e = engine(
        r#"{"version":1,"components":{"c":{"capabilities":{
             "a.send":{"allow":["chat:*"],"deny":["*@broadcast"]},
             "b.send":{"effect":"deny"}}}}}"#,
    );
    assert_eq!(e.check("c", "a.send", Some("chat:1"), T0), Decision::Allow);
    // matches allow and deny: refused
    assert_eq!(
        e.check("c", "a.send", Some("chat:1@broadcast"), T0),
        Decision::Deny(Reason::TargetDenied)
    );
    assert_eq!(e.check("c", "b.send", Some("chat:1"), T0), Decision::Deny(Reason::PolicyDenied));
    assert_eq!(e.check("c", "b.send", None, T0), Decision::Deny(Reason::PolicyDenied));
}

#[test]
fn an_allow_list_needs_a_target_to_match() {
    let mut e = whatsapp();
    assert_eq!(e.check("wa-whatsapp", "whatsapp.send", None, T0), Decision::Deny(Reason::TargetNotAllowed));
    assert_eq!(
        e.check("wa-whatsapp", "whatsapp.send", Some("chat:friend"), T0),
        Decision::Deny(Reason::TargetNotAllowed)
    );
    assert_eq!(
        e.check("wa-whatsapp", "whatsapp.send", Some("chat:1@broadcast"), T0),
        Decision::Deny(Reason::TargetDenied)
    );
    assert_eq!(e.check("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0), Decision::Allow);
}

#[test]
fn the_capability_bucket_allows_its_capacity_then_reports_an_exact_wait() {
    let mut e = engine(
        r#"{"version":1,"components":{"c":{"capabilities":{"cap.send":{"rate":{"per_minute":20}}}}}}"#,
    );
    for _ in 0..20 {
        assert_eq!(e.check("c", "cap.send", Some("t"), T0), Decision::Allow);
    }
    assert_eq!(
        e.check("c", "cap.send", Some("t"), T0),
        Decision::RateLimited { retry_after_ms: 3_000, reason: Reason::CapabilityRateLimited }
    );
    assert_eq!(
        e.check("c", "cap.send", Some("t"), T0 + 1_000),
        Decision::RateLimited { retry_after_ms: 2_000, reason: Reason::CapabilityRateLimited }
    );
    assert_eq!(e.check("c", "cap.send", Some("t"), T0 + 3_000), Decision::Allow);
    assert_eq!(e.capability_bucket_count(), 1);
}

#[test]
fn per_target_buckets_and_the_alerts_override() {
    let mut e = engine(
        r#"{"version":1,"components":{"c":{"capabilities":{"cap.send":{
             "allow":["*"],
             "rate":{"per_minute":20},
             "per_target":{"per_minute":6},
             "target_rates":[{"pattern":"chat:alerts","per_minute":1,"burst":1,"exempt_from_global":true}]}}}}}"#,
    );
    for _ in 0..6 {
        assert_eq!(e.check("c", "cap.send", Some("chat:a"), T0), Decision::Allow);
    }
    assert_eq!(
        e.check("c", "cap.send", Some("chat:a"), T0),
        Decision::RateLimited { retry_after_ms: 10_000, reason: Reason::TargetRateLimited }
    );
    // alerts: its own 1/min (the per-chat 6 does not apply) and no charge on the global bucket
    assert_eq!(e.check("c", "cap.send", Some("chat:alerts"), T0), Decision::Allow);
    assert_eq!(
        e.check("c", "cap.send", Some("chat:alerts"), T0),
        Decision::RateLimited { retry_after_ms: 60_000, reason: Reason::TargetRateLimited }
    );
    for i in 0..14 {
        assert_eq!(
            e.check("c", "cap.send", Some(format!("chat:o{i}").as_str()), T0),
            Decision::Allow,
            "one fresh per-chat bucket each; 6+14 = the 20 of the global cap"
        );
    }
    assert_eq!(
        e.check("c", "cap.send", Some("chat:z"), T0),
        Decision::RateLimited { retry_after_ms: 3_000, reason: Reason::CapabilityRateLimited }
    );
    // a minute later both refill; the exempt target still never touched the global bucket
    assert_eq!(e.check("c", "cap.send", Some("chat:z"), T0 + 60_000), Decision::Allow);
    assert_eq!(e.check("c", "cap.send", Some("chat:alerts"), T0 + 60_000), Decision::Allow);
}

#[test]
fn the_daily_cap_stops_the_day_and_rolls_over_at_utc_midnight() {
    let day_start = 5 * DAY_MS;
    let now = day_start + 1_000;
    let mut e = engine(
        r#"{"version":1,"components":{"c":{"capabilities":{"cap.send":{
             "rate":{"per_minute":100,"burst":100},"daily_cap":3}}}}}"#,
    );
    for _ in 0..3 {
        assert_eq!(e.check("c", "cap.send", Some("t"), now), Decision::Allow);
    }
    assert_eq!(
        e.check("c", "cap.send", Some("t"), now),
        Decision::RateLimited { retry_after_ms: DAY_MS - 1_000, reason: Reason::DailyCapReached }
    );
    assert_eq!(e.check("c", "cap.send", Some("t"), day_start + DAY_MS + 1), Decision::Allow);
}

#[test]
fn approval_is_needed_once_per_use_and_can_expire() {
    let mut e = engine(
        r#"{"version":1,"components":{"c":{"capabilities":{"credentials.read":{
             "require_approval":true,"rate":{"per_minute":4}}}}}}"#,
    );
    for _ in 0..3 {
        assert_eq!(
            e.check("c", "credentials.read", Some("WA_TOKEN"), T0),
            Decision::NeedsApproval(Reason::ApprovalRequired)
        );
    }
    // a held call must not have spent a token
    let state = e.approve("c", "credentials.read", Some("WA_TOKEN"), T0, Some(60_000));
    assert_eq!(state.uses, 1);
    assert_eq!(e.check("c", "credentials.read", Some("WA_TOKEN"), T0), Decision::Allow);
    assert_eq!(
        e.check("c", "credentials.read", Some("WA_TOKEN"), T0),
        Decision::NeedsApproval(Reason::ApprovalRequired),
        "one use per approval"
    );
    // 3 more approvals: the bucket (4/min) is the next wall, and the approval is not burned by it
    for _ in 0..3 {
        e.approve("c", "credentials.read", Some("WA_TOKEN"), T0, Some(60_000));
        assert_eq!(e.check("c", "credentials.read", Some("WA_TOKEN"), T0), Decision::Allow);
    }
    e.approve("c", "credentials.read", Some("WA_TOKEN"), T0, Some(60_000));
    assert_eq!(
        e.check("c", "credentials.read", Some("WA_TOKEN"), T0),
        Decision::RateLimited { retry_after_ms: 15_000, reason: Reason::CapabilityRateLimited }
    );
    assert_eq!(e.pending_approvals(T0).count(), 1, "the refused call kept its approval");

    // expiry: approved for a minute, checked after it
    e.clear_state();
    e.approve("c", "credentials.read", Some("WA_TOKEN"), T0, Some(60_000));
    assert_eq!(
        e.check("c", "credentials.read", Some("WA_TOKEN"), T0 + 60_000),
        Decision::NeedsApproval(Reason::ApprovalRequired)
    );
    // a capability-wide approval covers any target of that capability
    e.clear_state();
    e.approve("c", "credentials.read", None, T0, None);
    assert_eq!(e.check("c", "credentials.read", Some("OTHER_TOKEN"), T0), Decision::Allow);
    e.revoke_approvals("c", "credentials.read");
    assert_eq!(e.pending_approvals(T0).count(), 0);
}

struct FailingSink;

impl AuditSink for FailingSink {
    fn write(&mut self, _record: &AuditRecord) -> Result<(), AuditError> {
        Err(AuditError { sink: "memory", detail: "disk full".into() })
    }
}

#[test]
fn audit_records_every_sensitive_call_and_every_refusal_without_the_target_text() {
    let mut e = whatsapp();
    let mut audit = MemoryAudit::new();
    assert_eq!(e.enforce("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0, &mut audit), Decision::Allow);
    assert_eq!(e.enforce("wa-whatsapp", "whatsapp.send", None, T0, &mut audit), Decision::Deny(Reason::TargetNotAllowed));
    assert_eq!(
        e.enforce("wa-whatsapp", "whatsapp.send", Some("1-2@broadcast"), T0, &mut audit),
        Decision::Deny(Reason::TargetDenied)
    );
    // an ordinary capability is not audited when it is allowed…
    assert_eq!(e.enforce("wa-whatsapp", "log.write", None, T0, &mut audit), Decision::Allow);
    let records = audit.to_vec();
    assert_eq!(records.len(), 3);
    assert_eq!(records[0].decision, DecisionCode::Allow);
    assert_eq!(records[0].reason, "allowed");
    assert_eq!(records[1].decision, DecisionCode::Deny);
    assert_eq!(records[1].reason, "target_not_allowed");
    assert_eq!(records[2].reason, "target_denied");
    for record in &records {
        assert_eq!(record.ts_ms, T0);
        assert!(
            record.target == "-" || (record.target.starts_with("sha256:") && record.target.len() == 7 + 32),
            "{}",
            record.target
        );
        assert!(!record.target.contains('@'));
        assert!(!record.to_json_line().contains("chat:self"));
        assert_eq!(record.schema, RECORD_SCHEMA);
    }
    // …but a refusal of an ordinary capability is
    let mut audit = MemoryAudit::new();
    let mut refusing = engine(
        r#"{"version":1,"components":{"c":{"capabilities":{"log.write":{"effect":"deny"}}}}}"#,
    );
    assert_eq!(refusing.enforce("c", "log.write", None, T0, &mut audit), Decision::Deny(Reason::PolicyDenied));
    assert_eq!(audit.len(), 1);
}

#[test]
fn an_audit_failure_refuses_a_sensitive_call_unless_the_operator_opts_out() {
    let mut e = whatsapp();
    let mut sink = FailingSink;
    assert_eq!(
        e.enforce("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0, &mut sink),
        Decision::Deny(Reason::AuditUnavailable)
    );
    assert_eq!(e.audit_errors().len(), 1);
    assert!(!e.audit_errors()[0].detail.contains("chat:self"));
    // nothing was charged by the refused call: the budget is still whole
    let mut audit = MemoryAudit::new();
    for _ in 0..6 {
        assert_eq!(e.enforce("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0, &mut audit), Decision::Allow);
    }
    assert_eq!(
        e.check("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0),
        Decision::RateLimited { retry_after_ms: 10_000, reason: Reason::TargetRateLimited }
    );

    e.clear_state();
    e.set_fail_closed_on_audit(false);
    assert_eq!(
        e.enforce("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0, &mut sink),
        Decision::Allow
    );
    assert_eq!(e.take_audit_errors().len(), 2);
    assert!(e.audit_errors().is_empty());
}

#[test]
fn a_snapshot_carries_the_budgets_and_no_target_text() {
    let mut before = whatsapp();
    for _ in 0..6 {
        assert_eq!(before.check("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0), Decision::Allow);
    }
    assert_eq!(
        before.check("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0),
        Decision::RateLimited { retry_after_ms: 10_000, reason: Reason::TargetRateLimited }
    );
    let json = before.snapshot_json();
    assert!(!json.contains("chat:self"), "bucket keys are digests");
    assert_eq!(json.matches("sha256").count(), 0, "digests are bare hex in state keys");

    let mut after = whatsapp();
    after.restore_json(&json).expect("restore");
    assert_eq!(after.snapshot(), before.snapshot());
    assert_eq!(
        after.check("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0),
        Decision::RateLimited { retry_after_ms: 10_000, reason: Reason::TargetRateLimited }
    );
    assert_eq!(after.check("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0 + 10_000), Decision::Allow);

    // a different policy read from the same state still clamps to the new capacity
    let mut other = Engine::new(PolicySet::parse(WHATSAPP_POLICY).unwrap());
    other.restore_json(&json).unwrap();
    let strict = PolicySet::parse(
        r#"{"version":1,"components":{"wa-whatsapp":{"capabilities":{"whatsapp.send":{
             "allow":["chat:self"],"per_target":{"per_minute":1}}}}}}"#,
    )
    .unwrap();
    strict.validate().unwrap();
    other.set_policy(strict).unwrap();
    assert_eq!(
        other.check("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0),
        Decision::RateLimited { retry_after_ms: 60_000, reason: Reason::TargetRateLimited }
    );

    // bad snapshots are refused, never half-applied
    assert!(Engine::new(PolicySet::empty()).restore_json(r#"{"schema":2,"saved_at_ms":0}"#).is_err());
    assert!(Engine::new(PolicySet::empty())
        .restore_json(r#"{"schema":1,"saved_at_ms":0,"buckets":{"zzz":{"units":1,"last_ms":1}}}"#)
        .is_err());
    assert!(Engine::new(PolicySet::empty())
        .restore_json(r#"{"schema":1,"saved_at_ms":0,"daily":{"x":{"day":1,"count":1}}}"#)
        .is_err());
    assert!(Engine::new(PolicySet::empty()).restore_json("{").is_err());
}

#[test]
fn per_target_buckets_stay_bounded_and_evict_the_least_recently_used() {
    let mut e = engine(
        r#"{"version":1,"components":{"c":{"capabilities":{"cap.send":{
             "allow":["*"],"per_target":{"per_minute":6}}}}}}"#,
    );
    e.set_max_target_buckets(4);
    for i in 0..10 {
        assert_eq!(e.check("c", "cap.send", Some(format!("chat:{i}").as_str()), T0), Decision::Allow);
    }
    assert_eq!(e.target_bucket_count(), 4);
    // the newest targets are the ones still remembered: exhausted means still tracked
    assert_eq!(e.check("c", "cap.send", Some("chat:9"), T0), Decision::Allow);
    assert_eq!(e.capability_bucket_count(), 0, "no global bucket configured, none invented");
}

#[test]
fn peek_spends_nothing_and_decisions_are_reproducible() {
    let mut e = whatsapp();
    for _ in 0..50 {
        assert_eq!(e.peek("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0), Decision::Allow);
    }
    assert_eq!(e.target_bucket_count(), 0);
    assert_eq!(e.check("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0), Decision::Allow);

    let script: Vec<(&str, &str, Option<&str>, u64)> = vec![
        ("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0),
        ("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0),
        ("wa-whatsapp", "whatsapp.send", Some("chat:alerts"), T0),
        ("wa-whatsapp", "net.dial", Some("web.whatsapp.com:443"), T0),
        ("wa-whatsapp", "net.dial", Some("evil.example:443"), T0),
        ("wa-whatsapp", "exec.run", Some("sh"), T0),
        ("wa-whatsapp", "whatsapp.send", Some("chat:alerts"), T0 + 60_000),
    ];
    let run = |policy: &str| {
        let mut e = Engine::new(PolicySet::parse(policy).unwrap());
        script.iter().map(|(c, cap, t, now)| e.check(c, cap, *t, *now)).collect::<Vec<_>>()
    };
    let a = run(WHATSAPP_POLICY);
    let b = run(WHATSAPP_POLICY);
    assert_eq!(a, b);
    assert_eq!(a[3], Decision::Allow);
    assert_eq!(a[4], Decision::Deny(Reason::TargetNotAllowed));
    assert_eq!(a[5], Decision::Deny(Reason::NoPolicy));
}

#[test]
fn retry_after_is_the_wait_a_host_can_sleep_on() {
    let mut e = engine(
        r#"{"version":1,"components":{"c":{"capabilities":{"cap.send":{"rate":{"per_minute":4}}}}}}"#,
    );
    for _ in 0..4 {
        assert_eq!(e.check("c", "cap.send", Some("t"), T0), Decision::Allow);
    }
    let waited = match e.check("c", "cap.send", Some("t"), T0) {
        Decision::RateLimited { retry_after_ms, .. } => retry_after_ms,
        other => panic!("expected a rate limit, got {other}"),
    };
    assert_eq!(waited, 15_000);
    assert_eq!(e.check("c", "cap.send", Some("t"), T0 + waited - 1), Decision::RateLimited { retry_after_ms: 1, reason: Reason::CapabilityRateLimited });
    assert_eq!(e.check("c", "cap.send", Some("t"), T0 + waited), Decision::Allow);
}

#[test]
fn target_mode_controls_what_the_trail_says() {
    let mut e = whatsapp();
    let mut audit = MemoryAudit::new();
    e.set_target_mode(TargetMode::Redacted);
    e.enforce("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0, &mut audit);
    e.set_target_mode(TargetMode::Exact);
    e.enforce("wa-whatsapp", "whatsapp.send", Some("chat:self"), T0, &mut audit);
    let records = audit.to_vec();
    assert_eq!(records[0].target, "<redacted>");
    assert_eq!(records[1].target, "chat:self");
    assert_eq!(audit_target(TargetMode::Digest, "chat:self").len(), 7 + 32);
}
