//! Speech through the fabric: `wa-stt-remote` is the first user of `rust/wa-fabric`.
//!
//! Phase 2 of the queue (`docs/QUEUE.md`) decided remote-vs-local from one number — is the
//! `stt_worker` node attached, and was its last decode faster than this node's. The fabric generalises
//! that decision to a fleet: every node publishes its capabilities and load, every node scores the
//! candidates, and the winner is asked directly. This module is the seam between the two, and it is
//! deliberately a **translation**, not a second policy:
//!
//! | fabric plan | speech decision |
//! | --- | --- |
//! | `Offer { to, .. }` (a peer accepted) | [`Decision::Remote`] with [`RemoteReason::FabricPlaced`], holding the local worker back for one short grace |
//! | `Local { .. }` (self was cheapest, or nothing answered) | [`Decision::Local`] with [`LocalReason::FabricLocal`], taken immediately |
//! | *no placement* (the fabric is off) | [`Preference::decide`], byte for byte the pre-fabric behaviour |
//!
//! Two properties matter:
//!
//! * **The flag off is the old path, not a copy of it.** With no placement the old `Preference`
//!   decides, so "the fabric changed nothing when it is off" is true by construction
//!   (`tests::without_a_placement_the_old_policy_decides`).
//! * **The grace stays bounded.** A peer that accepted an offer is one call away from taking the
//!   lease, so the local worker holds back [`FABRIC_GRACE_MS`] — not the 3 s the old policy used to
//!   give a node that might be asleep. If the peer's take does not arrive, the local worker takes the
//!   job itself and the queue's "first lease wins" keeps it single.

use wa_queue::Clock;

use crate::metrics::Metrics;
use crate::policy::{Decision, Latency, LocalReason, Preference, RemoteHealth, RemoteReason};

/// How long the local worker holds back for a peer the fabric just placed a job on. The offer round
/// trip already happened inside `route`, so the peer's `take` is one call away; a quarter second is
/// generous for a relay hop and short enough that a person never notices a fallback.
pub const FABRIC_GRACE_MS: i64 = 250;

/// Decide what this node's local worker does with the next ready speech job, given the fabric's
/// placement when there is one.
///
/// `placement` is `None` when the fabric is disabled or has not been wired (a node that has not
/// upgraded yet): the pre-fabric [`Preference`] then decides, unchanged.
pub fn decide(
    now_ms: i64,
    enqueued_at_ms: i64,
    remote: Option<&RemoteHealth>,
    local: &Latency,
    preference: &Preference,
    placement: Option<&wa_fabric::Decision>,
) -> Decision {
    let Some(placement) = placement else {
        return preference.decide(now_ms, enqueued_at_ms, remote, local);
    };
    match &placement.plan {
        wa_fabric::Plan::Offer { .. } => Decision::Remote {
            grace_until_ms: now_ms.saturating_add(FABRIC_GRACE_MS),
            because: RemoteReason::FabricPlaced,
        },
        // The fabric's local plan is already the answer: self was the cheapest candidate, or nothing
        // answered inside the window. Waiting again would spend a second window on a decision that
        // has been made.
        wa_fabric::Plan::Local { .. } => Decision::Local { because: LocalReason::FabricLocal },
    }
}

/// The same decision, counting what it did. The counters are the old ones on purpose: an operator's
/// "how often did the strong node do it" question must not change meaning when the fabric is on.
pub fn decide_counted(
    now_ms: i64,
    enqueued_at_ms: i64,
    remote: Option<&RemoteHealth>,
    local: &Latency,
    preference: &Preference,
    placement: Option<&wa_fabric::Decision>,
    metrics: &mut Metrics,
) -> Decision {
    let decision = decide(now_ms, enqueued_at_ms, remote, local, preference, placement);
    if placement.is_some() {
        metrics.fabric_decisions += 1;
    }
    decision
}

/// One speech job's placement request, as the fabric wants it: the kind, the job id and how big the
/// payload is (a 30 s voice note is small; the fabric's locality term only prices big payloads).
pub fn request(job: u64, audio_bytes: usize) -> wa_fabric::Request {
    wa_fabric::Request::new("stt", job, audio_bytes as u64)
}

/// The placement for one speech job, from the node's live view. `None` when the fabric is off, so the
/// caller's `decide` falls back to the pre-fabric policy.
pub fn place(
    view: &wa_fabric::PresenceView,
    config: &wa_fabric::Config,
    clock: &dyn Clock,
    self_id: &str,
    job: u64,
    audio_bytes: usize,
    latency: &dyn wa_fabric::Latency,
) -> Option<wa_fabric::Decision> {
    if !config.enabled {
        return None;
    }
    let request = request(job, audio_bytes).affinity(self_id.to_string());
    Some(wa_fabric::placement::choose(view, &request, self_id, clock.now_ms(), config, latency))
}

#[cfg(test)]
mod tests {
    use super::*;
    use wa_fabric::presence::{Heartbeat, Load, PresenceView};
    use wa_fabric::Config;

    fn latency(ms: i64) -> Latency {
        let mut latency = Latency::new();
        latency.record(1_000, ms);
        latency.record(1_000, ms);
        latency
    }

    fn view(now: i64, self_load: Load, peer_load: Load) -> PresenceView {
        let config = Config::default();
        let mut view = PresenceView::new(&config);
        view.observe(Heartbeat::new("this", ["stt"], self_load, "0.1.0", now), now);
        view.observe(Heartbeat::new("strong", ["stt"], peer_load, "0.1.0", now), now);
        view
    }

    #[test]
    fn without_a_placement_the_old_policy_decides() {
        let preference = Preference::default();
        let local = latency(4_000);
        let remote = RemoteHealth::online(latency(900));
        let now = 10_000;
        for enqueued in [now - 10_000, now - 3_000, now] {
            assert_eq!(
                decide(now, enqueued, Some(&remote), &local, &preference, None),
                preference.decide(now, enqueued, Some(&remote), &local)
            );
            assert_eq!(
                decide(now, enqueued, None, &local, &preference, None),
                preference.decide(now, enqueued, None, &local)
            );
        }
    }

    #[test]
    fn a_fabric_offer_holds_the_local_worker_back_for_one_short_grace() {
        let config = Config::default();
        let now = 10_000;
        // The strong node is idle, this one is busy: the fabric offers it to the peer.
        let view = view(now, Load::new(4, 70, 40), Load::new(0, 5, 20));
        let placement = place(&view, &config, &wa_queue::FixedClock::new(now), "this", 7, 40_000, &()).expect("placed");
        assert!(matches!(placement.plan, wa_fabric::Plan::Offer { .. }));
        let decision = decide(now, now, None, &latency(5_000), &Preference::default(), Some(&placement));
        assert_eq!(
            decision,
            Decision::Remote { grace_until_ms: now + FABRIC_GRACE_MS, because: RemoteReason::FabricPlaced }
        );
        // The old policy, with the remote measured slower, would have taken it immediately; the
        // fabric's own view is the newer evidence, so it wins.
        assert_eq!(
            Preference::default().decide(now, now, Some(&RemoteHealth::online(latency(9_000))), &latency(1_000)),
            Decision::Local { because: LocalReason::RemoteSlower }
        );
    }

    #[test]
    fn a_fabric_local_plan_is_taken_at_once() {
        let config = Config::default();
        let now = 10_000;
        // Both nodes are idle: a tie, and local costs no round trip.
        let view = view(now, Load::new(0, 10, 10), Load::new(0, 10, 10));
        let placement = place(&view, &config, &wa_queue::FixedClock::new(now), "this", 8, 40_000, &()).expect("placed");
        assert!(placement.plan.is_local());
        assert_eq!(
            decide(now, now, Some(&RemoteHealth::online(latency(100))), &latency(5_000), &Preference::default(), Some(&placement)),
            Decision::Local { because: LocalReason::FabricLocal }
        );
    }

    #[test]
    fn the_flag_off_returns_no_placement_at_all() {
        let config = Config { enabled: false, ..Config::default() };
        let now = 10_000;
        let view = view(now, Load::new(9, 90, 90), Load::new(0, 1, 1));
        assert_eq!(place(&view, &config, &wa_queue::FixedClock::new(now), "this", 9, 1_000, &()), None);
        let mut metrics = Metrics::new();
        let decision = decide_counted(now, now, None, &latency(1_000), &Preference::default(), None, &mut metrics);
        assert_eq!(metrics.fabric_decisions, 0);
        assert!(matches!(decision, Decision::Local { .. }), "off is the old local path");
    }

    #[test]
    fn a_fabric_decision_is_counted_without_changing_the_old_counters() {
        let config = Config::default();
        let now = 10_000;
        let view = view(now, Load::new(4, 70, 40), Load::new(0, 5, 20));
        let placement = place(&view, &config, &wa_queue::FixedClock::new(now), "this", 10, 40_000, &()).expect("placed");
        let mut metrics = Metrics::new();
        let decision = decide_counted(now, now, None, &latency(5_000), &Preference::default(), Some(&placement), &mut metrics);
        assert!(matches!(decision, Decision::Remote { .. }));
        assert_eq!(metrics.fabric_decisions, 1);
        assert_eq!(metrics.waited_for_remote, 0, "the old counters are the caller's to bump");
    }
}
