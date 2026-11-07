//! The kernel half of a drained hot swap: wait for a retired instance to finish the work in hand
//! instead of stopping it and letting the replacement run the same job again.
//!
//! The problem this solves is at-least-once, and it is measurable: `services::replace` stops the old
//! instance, and only then hands its in-flight queue leases back (`wa_queue::Queue::handover`). A job
//! whose effect was half-applied - a message sent but not settled, an index write landing twice - is
//! therefore retried by the new instance. The queue's fencing makes that *safe* (a handed-over job
//! cannot be settled twice), but it is still a second attempt at work that did not fail.
//!
//! So a swap asks first. The contract is `wa:kernel/drain@0.2.0` (`wit/kernel-v2/kernel.wit`):
//!
//! 1. the kernel sets `draining` (`Shared::draining`) - "take no new work";
//! 2. the guest finishes the `handle` it is in, settles it, and calls `idle()`;
//! 3. the kernel stops the instance, and hands over whatever it still holds - nothing, normally.
//!
//! Three cases keep the old behaviour, deliberately and visibly:
//!
//! * **no hook** - the artifact does not import the interface (`service_components_v2::drains`), so
//!   nothing is waited for and the leases go back for a retry, exactly as before;
//! * **nothing in flight** - the instance holds no lease, so there is no job to protect and waiting
//!   for a tick would only slow the swap down;
//! * **deadline exceeded** - the guest did not report idle within `WA_SERVICE_DRAIN_MS` (30 s by
//!   default). The swap then does what it always did: stop, hand the leases over, let the
//!   replacement retry. It is logged as a warning, because it means a component that promises to
//!   drain did not.
//!
//! The wait is a poll of one atomic, not a channel: the guest can report idle at any point of its own
//! loop, the kernel has no way to be woken by a host function on another thread, and the poll costs
//! nothing while a swap is in progress (5 ms, and a swap happens once per upgrade).
//!
//! **The risk this carries, named**: the wait is bounded by the deadline, and the deadline is the
//! only thing standing between a guest that reports idle late and a swap that hung. A component that
//! takes longer than 30 s to finish one job therefore still gets its job retried (correctly fenced),
//! and an operator who knows their jobs are longer must raise `WA_SERVICE_DRAIN_MS`; the swap answer
//! and the log line say `deadline`, so this is visible rather than silent. The second risk: `idle`
//! is the guest's word. A guest that reports it while still holding work would be stopped mid-job -
//! but the queue's lease is the host's own evidence, and the *count* the kernel reads before waiting
//! is what decides whether a job is at stake, so a lying guest loses its own job, not the queue's
//! exactly-once property.

use crate::services::Shared;
use serde_json::{json, Value};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// How long a swap waits for the retired instance to report idle, when `WA_SERVICE_DRAIN_MS` is not
/// set. Long enough for a send or an index write (a WhatsApp send is sub-second, a history index
/// write is bounded by its own budget), short enough that an upgrade an operator asked for finishes
/// in a watchable time even when the guest never answers.
pub const DEFAULT_DEADLINE: Duration = Duration::from_secs(30);

/// How often the wait looks at the guest's answer. The guest's own tick is coarser than this
/// (`TICK` in a service loop is 50-200 ms), so the poll is not what a drain costs.
const POLL: Duration = Duration::from_millis(5);

/// The drain deadline: `WA_SERVICE_DRAIN_MS` when set and sane, else [`DEFAULT_DEADLINE`].
///
/// A knob and not a constant because "how long is one job" is a property of the component, which the
/// kernel cannot know: 30 s is a guess that is right for a message send and wrong for a batch import.
/// `0` disables waiting entirely (every swap behaves as it did before the drain existed), which is
/// the honest setting for a node whose components must never delay an upgrade.
pub fn deadline() -> Duration {
    match std::env::var("WA_SERVICE_DRAIN_MS").ok().and_then(|text| text.trim().parse::<u64>().ok()) {
        Some(ms) => Duration::from_millis(ms),
        None => DEFAULT_DEADLINE,
    }
}

/// Why a swap stopped waiting. The word is what the log line and the swap answer carry; it is a
/// closed set so a dashboard can count the cases without parsing prose.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The guest reported idle after finishing its work: nothing was handed back.
    Drained,
    /// The guest did not report idle before the deadline: stop and hand the leases over (old path).
    Deadline,
    /// The artifact does not implement the drain: stop immediately (old path).
    NoHook,
    /// The instance held no queue lease: stop immediately, there is no job to protect.
    NothingInFlight,
}

impl Outcome {
    pub fn as_str(&self) -> &'static str {
        match self {
            Outcome::Drained => "drained",
            Outcome::Deadline => "deadline",
            Outcome::NoHook => "no_hook",
            Outcome::NothingInFlight => "nothing_in_flight",
        }
    }
}

/// What one retirement did: the outcome, how long it was waited for, and the leases that were at
/// stake when the swap began.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Draining {
    pub outcome: Outcome,
    pub waited_ms: u64,
    /// In-flight queue leases of the retired instance when the swap started.
    pub in_flight: usize,
    pub deadline_ms: u64,
}

impl Draining {
    /// The swap answer's `drain` object. Counts and a word, never a payload
    /// (`docs/OBSERVABILITY.md`): a job id or a chat would be the kind of thing a log must not carry.
    pub fn to_json(&self) -> Value {
        json!({
            "outcome": self.outcome.as_str(),
            "waited_ms": self.waited_ms,
            "in_flight": self.in_flight,
            "deadline_ms": self.deadline_ms,
        })
    }

    /// The line this retirement writes into the retired component's own service log, so
    /// `services logs <name>` answers "why was my job retried" without a second surface.
    ///
    /// `handed_over` is filled by the caller, after the stop, because it is the number the queue
    /// itself reports (`Queue::handover`) rather than a count this module predicted.
    pub fn log_line(&self, handed_over: usize) -> String {
        let waited = self.waited_ms;
        match self.outcome {
            Outcome::Drained => format!(
                "INFO drain: drained in {waited}ms, {} in flight, nothing handed back",
                self.in_flight
            ),
            Outcome::Deadline => format!(
                "WARN drain: deadline exceeded after {waited}ms (limit {}ms) with {} in flight; stopped and handed {handed_over} lease(s) back for a retry",
                self.deadline_ms, self.in_flight
            ),
            Outcome::NoHook => format!(
                "INFO drain: no wa:kernel/drain hook in this artifact; stopped immediately and handed {handed_over} lease(s) back"
            ),
            Outcome::NothingInFlight => format!("INFO drain: nothing in flight; stopped immediately and handed {handed_over} lease(s) back"),
        }
    }
}

/// Ask a retired instance to drain, and say what happened. Does **not** stop anything: the caller
/// (`services::replace`) stops and joins, then hands the leases over and logs the result.
///
/// `in_flight` is a function so the count is read at the one moment that matters (after the guest's
/// own registrations exist, before the flag is set) and so this module needs no queue to be tested.
pub(crate) fn retire(shared: &Arc<Shared>, aware: bool, in_flight: impl FnOnce() -> usize, deadline: Duration) -> Draining {
    let began = Instant::now();
    let deadline_ms = deadline.as_millis() as u64;
    if !aware {
        return Draining { outcome: Outcome::NoHook, waited_ms: 0, in_flight: 0, deadline_ms };
    }
    let in_flight = in_flight();
    if in_flight == 0 {
        return Draining { outcome: Outcome::NothingInFlight, waited_ms: 0, in_flight, deadline_ms };
    }
    shared.draining.store(true, Ordering::Relaxed);
    let until = began + deadline;
    loop {
        if shared.idle.load(Ordering::Relaxed) {
            return Draining {
                outcome: Outcome::Drained,
                waited_ms: began.elapsed().as_millis() as u64,
                in_flight,
                deadline_ms,
            };
        }
        let now = Instant::now();
        if now >= until {
            return Draining {
                outcome: Outcome::Deadline,
                waited_ms: began.elapsed().as_millis() as u64,
                in_flight,
                deadline_ms,
            };
        }
        std::thread::sleep(POLL.min(until - now));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A `Shared` is the runner's per-instance state; a drain only ever touches two flags of it, so
    /// the tests build the smallest one that answers the question instead of starting a component.
    fn shared() -> Arc<Shared> {
        Arc::new(Shared::default())
    }

    /// The guest's answer, from another thread, after `after` - one instant of a service loop.
    fn answer_later(shared: &Arc<Shared>, after: Duration, drains: bool) -> std::thread::JoinHandle<()> {
        let shared = shared.clone();
        std::thread::spawn(move || {
            std::thread::sleep(after);
            if drains && shared.draining.load(Ordering::Relaxed) {
                shared.idle.store(true, Ordering::Relaxed);
            }
        })
    }

    /// The normal case: the swap waits, the guest settles its job and reports idle, nothing is
    /// handed back for a retry - so the replacement never runs the job a second time.
    #[test]
    fn a_drain_waits_for_the_job_in_hand_and_then_stops() {
        let shared = shared();
        let guest = answer_later(&shared, Duration::from_millis(120), true);
        let begun = Instant::now();
        let drained = retire(&shared, true, || 1, Duration::from_secs(5));
        guest.join().unwrap();
        assert_eq!(drained.outcome, Outcome::Drained, "{drained:?}");
        assert!(begun.elapsed() >= Duration::from_millis(120), "it waited for the guest, not for the clock");
        assert!(begun.elapsed() < Duration::from_secs(2), "and it did not wait for the deadline");
        assert_eq!(drained.in_flight, 1, "the count is what the swap saw before asking");
        let line = drained.log_line(0);
        assert!(line.contains("drained in") || line.starts_with("INFO drain: drained"), "{line}");
        assert!(line.contains("nothing handed back"), "{line}");
    }

    /// The deadline path: a guest that promises to drain and does not. The swap gives up, stops, and
    /// says so at WARN with the number the queue handed back - today's behaviour, made visible.
    #[test]
    fn the_deadline_falls_back_to_the_old_stop_and_retry_and_says_so() {
        let shared = shared();
        let begun = Instant::now();
        let drained = retire(&shared, true, || 2, Duration::from_millis(150));
        let elapsed = begun.elapsed();
        assert_eq!(drained.outcome, Outcome::Deadline, "{drained:?}");
        assert!(elapsed >= Duration::from_millis(150), "it waited the deadline: {elapsed:?}");
        assert!(elapsed < Duration::from_millis(900), "and no longer: {elapsed:?}");
        assert_eq!(drained.in_flight, 2);
        assert!(shared.draining.load(Ordering::Relaxed), "the guest was asked, at least");
        let line = drained.log_line(2);
        assert!(line.starts_with("WARN drain: deadline exceeded"), "{line}");
        assert!(line.contains("handed 2 lease(s) back"), "{line}");
        assert_eq!(drained.to_json()["outcome"], "deadline");
    }

    /// A component without the hook: not asked, not waited for. This is the `svc-echo` case, and the
    /// property the whole design has to keep - the drain must not slow a swap down for a component
    /// that cannot drain.
    #[test]
    fn an_artifact_without_the_hook_is_not_waited_for() {
        let shared = shared();
        let begun = Instant::now();
        let drained = retire(&shared, false, || 3, Duration::from_secs(30));
        assert_eq!(drained.outcome, Outcome::NoHook, "{drained:?}");
        assert!(begun.elapsed() < Duration::from_millis(50), "no wait at all: {:?}", begun.elapsed());
        assert!(!shared.draining.load(Ordering::Relaxed), "a guest that cannot hear it is not asked");
        assert!(drained.log_line(3).contains("handed 3 lease(s) back"));
    }

    /// Nothing in flight: the instance holds no lease, so there is no job to protect and waiting for a
    /// tick would only delay the upgrade. The guest is not asked either (it may be parked).
    #[test]
    fn nothing_in_flight_is_not_waited_for() {
        let shared = shared();
        let begun = Instant::now();
        let drained = retire(&shared, true, || 0, Duration::from_secs(30));
        assert_eq!(drained.outcome, Outcome::NothingInFlight, "{drained:?}");
        assert!(begun.elapsed() < Duration::from_millis(50), "no wait at all: {:?}", begun.elapsed());
        assert!(!shared.draining.load(Ordering::Relaxed));
        assert!(drained.log_line(0).contains("nothing in flight"));
    }

    /// `idle` said before the deadline but after the work: the flag is what the wait reads, so a guest
    /// that reports early (a swap that arrived while it was already idle) is not waited out.
    #[test]
    fn an_idle_report_already_present_ends_the_wait_at_once() {
        let shared = shared();
        shared.draining.store(true, Ordering::Relaxed);
        shared.idle.store(true, Ordering::Relaxed);
        let begun = Instant::now();
        let drained = retire(&shared, true, || 1, Duration::from_secs(30));
        assert_eq!(drained.outcome, Outcome::Drained);
        assert!(begun.elapsed() < Duration::from_millis(50), "{:?}", begun.elapsed());
    }

    /// The knob: a parse of `WA_SERVICE_DRAIN_MS`, and the default when it is absent or nonsense. The
    /// variable is process-wide, so this is the one test that sets it - and it puts it back.
    #[test]
    fn the_deadline_is_a_knob_with_the_30_second_default() {
        let previous = std::env::var("WA_SERVICE_DRAIN_MS").ok();
        std::env::remove_var("WA_SERVICE_DRAIN_MS");
        assert_eq!(deadline(), DEFAULT_DEADLINE);
        std::env::set_var("WA_SERVICE_DRAIN_MS", "250");
        assert_eq!(deadline(), Duration::from_millis(250));
        std::env::set_var("WA_SERVICE_DRAIN_MS", "not-a-number");
        assert_eq!(deadline(), DEFAULT_DEADLINE);
        match previous {
            Some(value) => std::env::set_var("WA_SERVICE_DRAIN_MS", value),
            None => std::env::remove_var("WA_SERVICE_DRAIN_MS"),
        }
    }
}
