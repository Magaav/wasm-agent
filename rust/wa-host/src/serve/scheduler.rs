//! Run admission: who may run, where, and in what order.
//!
//! A **run** is one execution in a session. Runs became concurrent once they were routed by
//! session, and routing by session alone is not enough: the dispatcher used to look only at
//! sessions *currently running*, so two runs admitted back to back for a session nobody was
//! running yet could land on two workers and write one conversation twice. This module makes
//! the admission itself the atomic act.
//!
//! Three rules, and each one is a failure this module exists to prevent:
//!
//! 1. **One writer per conversation, from admission to completion.** Ownership is claimed
//!    when the run is admitted, not when it starts, and is held through the whole queued +
//!    running lifetime. A second run for the same conversation is *behind* the owner and
//!    cannot be handed to a different worker. This is what keeps a conversation's runs
//!    ordered even when they arrive back to back.
//! 2. **Identity is not conversation.** The authenticated identity (`owner`) decides what a
//!    run may do; the conversation decides what it may write and therefore what serialises.
//!    They travel separately, and ownership is on the conversation.
//! 3. **Interactive capacity is reserved.** Worker 0 is the interactive reserve: a background
//!    run (a wake, an automation) may not occupy it, so a flood of background work cannot
//!    take the worker a person's next run needs. Background runs are additionally bounded in
//!    both concurrency and backlog, and a conversation's own backlog is bounded so one
//!    conversation cannot fill a worker's queue.
//!
//! The class marker is deliberately one-way. `X-WA-Run-Class: background` demotes a run into
//! the background lane. Any other value, including `interactive`, is ignored: no request
//! header grants reserved capacity, so an untrusted caller cannot promote itself. Relayed
//! peer runs are classified background by the node itself, never by a header.
//!
//! The module is pure policy over an abstract "pick a worker" callback, so the ordering and
//! capacity rules are unit-testable without sockets or an interpreter.

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, OnceLock};

/// Which lane a run belongs to. The default is interactive because the common case is a person
/// waiting; the marker can only move a run *out* of that default, never into a privilege.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RunClass {
    Interactive,
    Background,
}

impl RunClass {
    /// The one accepted marker, and it can only demote.
    ///
    /// `background` (case-insensitive, trimmed) selects the background lane. Every other value
    /// - `interactive`, an unknown word, an empty value - keeps the default. That asymmetry is
    /// the security property: there is no header value that grants the interactive reserve, so
    /// there is nothing an untrusted caller can claim.
    pub fn from_header(value: &str) -> RunClass {
        if value.trim().eq_ignore_ascii_case("background") {
            RunClass::Background
        } else {
            RunClass::Interactive
        }
    }
}

/// Why a run was refused. Each maps to an explicit 503 so a caller is told to retry rather than
/// left holding a socket.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Refusal {
    /// This conversation already has its bounded backlog full. Retry when it drains.
    SessionQueueFull,
    /// The background lane is at its concurrency + backlog bound.
    BackgroundQueueFull,
}

impl Refusal {
    /// `(error code, hint)` for the 503 body.
    pub fn as_error(self) -> (&'static str, &'static str) {
        match self {
            Refusal::SessionQueueFull => (
                "session_queue_full",
                "this conversation already has the maximum number of runs queued; retry when it drains",
            ),
            Refusal::BackgroundQueueFull => (
                "background_queue_full",
                "the background run lane is full; retry shortly",
            ),
        }
    }
}

/// What admission decided.
#[derive(Debug, PartialEq)]
pub enum Decision {
    /// Run on this worker. The conversation is now owned by it until `complete`.
    Run { run_id: u64, worker: usize },
    /// The conversation is owned by this worker; queue behind it there.
    Behind { run_id: u64, worker: usize },
    /// No room. The caller replies 503 and admits nothing.
    Refused(Refusal),
}

/// The bounds. `background_max` is concurrent background conversations; `background_backlog` is
/// how many more may be admitted and waiting; `session_queue_depth` bounds one conversation's
/// own backlog (running run included).
#[derive(Clone, Copy, Debug)]
pub struct Config {
    pub session_queue_depth: usize,
    pub background_max: usize,
    pub background_backlog: usize,
}

impl Default for Config {
    fn default() -> Self {
        Config { session_queue_depth: 4, background_max: 4, background_backlog: 8 }
    }
}

struct Owner {
    worker: usize,
    class: RunClass,
    /// Admitted runs for this conversation that have not completed: running + queued behind.
    pending: usize,
}

#[derive(Default)]
struct Inner {
    owners: HashMap<String, Owner>,
    next_run_id: u64,
}

/// The admission table. A `Mutex` rather than atomics because admission is a decision over the
/// whole table (ownership, lane counts and the worker pick must be one step), and the table is
/// touched a handful of times per run, never in a hot loop.
pub struct Scheduler {
    inner: Mutex<Inner>,
    config: Config,
}

impl Scheduler {
    pub fn new(config: Config) -> Self {
        Scheduler { inner: Mutex::new(Inner::default()), config }
    }

    /// Claim a place for a run. `pick` chooses a worker for a conversation nobody owns; it is
    /// called at most once, under the lock, and is told which workers are already claimed so two
    /// admissions cannot both choose the same idle worker.
    pub fn admit<F>(&self, conversation: &str, class: RunClass, pick: F) -> Decision
    where
        F: FnOnce(RunClass, &HashSet<usize>) -> Option<usize>,
    {
        let mut inner = self.inner.lock().unwrap_or_else(|poison| poison.into_inner());
        inner.next_run_id = inner.next_run_id.wrapping_add(1);
        let run_id = inner.next_run_id;

        // 1. Same conversation: queue behind its owner. This is the whole of same-session ordering.
        if !conversation.is_empty() {
            if let Some(owner) = inner.owners.get_mut(conversation) {
                if owner.pending >= self.config.session_queue_depth {
                    return Decision::Refused(Refusal::SessionQueueFull);
                }
                owner.pending += 1;
                return Decision::Behind { run_id, worker: owner.worker };
            }
        }

        // 2. Lane capacity. Background work is bounded before it is ever handed a worker, so a
        //    burst of wakes cannot grow without limit while it waits.
        if class == RunClass::Background {
            let background = inner
                .owners
                .values()
                .filter(|owner| owner.class == RunClass::Background)
                .count();
            if background >= self.config.background_max.saturating_add(self.config.background_backlog) {
                return Decision::Refused(Refusal::BackgroundQueueFull);
            }
        }

        // 3. Choose a worker for a conversation nobody owns. The claimed set closes the gap
        //    between "admitted" and "started": a worker reserved for a run that has not begun is
        //    not offered to a different conversation.
        let claimed: HashSet<usize> = inner.owners.values().map(|owner| owner.worker).collect();
        let Some(worker) = pick(class, &claimed) else {
            return Decision::Refused(match class {
                RunClass::Background => Refusal::BackgroundQueueFull,
                RunClass::Interactive => Refusal::SessionQueueFull,
            });
        };
        if !conversation.is_empty() {
            inner.owners.insert(conversation.to_string(), Owner { worker, class, pending: 1 });
        }
        Decision::Run { run_id, worker }
    }

    /// A run finished (or was never delivered). Releases one place in its conversation's backlog;
    /// when the last place goes, the conversation is unowned and free to run elsewhere.
    pub fn complete(&self, conversation: &str) {
        if conversation.is_empty() {
            return;
        }
        let mut inner = self.inner.lock().unwrap_or_else(|poison| poison.into_inner());
        if let Some(owner) = inner.owners.get_mut(conversation) {
            owner.pending = owner.pending.saturating_sub(1);
            if owner.pending == 0 {
                inner.owners.remove(conversation);
            }
        }
    }

    /// Observability: the conversations currently owned and their pending counts. `/health` does
    /// not need this, but a test and an operator reading the node do.
    pub fn snapshot(&self) -> Vec<(String, usize, RunClass, usize)> {
        let inner = self.inner.lock().unwrap_or_else(|poison| poison.into_inner());
        let mut rows: Vec<_> = inner
            .owners
            .iter()
            .map(|(conversation, owner)| (conversation.clone(), owner.worker, owner.class, owner.pending))
            .collect();
        rows.sort_by(|a, b| a.0.cmp(&b.0));
        rows
    }

    pub fn config(&self) -> Config {
        self.config
    }
}

/// The process-wide scheduler, installed once by `run()`. The worker loop and the accept thread
/// both need it, and there is exactly one node per process.
static SCHEDULER: OnceLock<Scheduler> = OnceLock::new();

pub fn install(config: Config) {
    let _ = SCHEDULER.set(Scheduler::new(config));
}

pub fn global() -> Option<&'static Scheduler> {
    SCHEDULER.get()
}

pub fn admit(conversation: &str, class: RunClass, pick: impl FnOnce(RunClass, &HashSet<usize>) -> Option<usize>) -> Decision {
    match global() {
        Some(scheduler) => scheduler.admit(conversation, class, pick),
        // Before `run()` installs the scheduler (unit tests that never serve), every run is
        // unrouted and goes to worker 0, exactly as a single-interpreter node did.
        None => Decision::Run { run_id: 0, worker: 0 },
    }
}

pub fn complete(conversation: &str) {
    if let Some(scheduler) = global() {
        scheduler.complete(conversation);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scheduler() -> Scheduler {
        Scheduler::new(Config { session_queue_depth: 3, background_max: 2, background_backlog: 2 })
    }

    /// The regression this module was written for: two runs admitted back to back for a
    /// conversation nobody is running yet must go to the *same* worker, the second behind the
    /// first, or a conversation is written twice.
    #[test]
    fn back_to_back_admissions_for_one_conversation_share_an_owner() {
        let scheduler = scheduler();
        let first = scheduler.admit("conversation-a", RunClass::Interactive, |_, _| Some(0));
        assert!(matches!(first, Decision::Run { worker: 0, .. }));
        let second = scheduler.admit("conversation-a", RunClass::Interactive, |_, _| Some(1));
        match second {
            Decision::Behind { worker, .. } => assert_eq!(worker, 0, "the second run must follow its owner, not a fresh worker"),
            other => panic!("expected Behind, got {other:?}"),
        }
        // The pick closure is never consulted while the conversation is owned.
        let third = scheduler.admit("conversation-a", RunClass::Interactive, |_, _| panic!("must not pick"));
        assert!(matches!(third, Decision::Behind { worker: 0, .. }));
    }

    /// Completion frees the conversation, and the next run may land elsewhere.
    #[test]
    fn completion_releases_ownership() {
        let scheduler = scheduler();
        scheduler.admit("conversation-a", RunClass::Interactive, |_, _| Some(0));
        scheduler.complete("conversation-a");
        let next = scheduler.admit("conversation-a", RunClass::Interactive, |_, _| Some(2));
        assert!(matches!(next, Decision::Run { worker: 2, .. }));
    }

    /// A conversation's backlog is bounded; the run that exceeds it is refused, not queued forever.
    #[test]
    fn a_conversations_backlog_is_bounded() {
        let scheduler = scheduler();
        scheduler.admit("c", RunClass::Interactive, |_, _| Some(0));
        scheduler.admit("c", RunClass::Interactive, |_, _| None); // behind, pending 2
        scheduler.admit("c", RunClass::Interactive, |_, _| None); // behind, pending 3 == depth
        assert_eq!(scheduler.admit("c", RunClass::Interactive, |_, _| None), Decision::Refused(Refusal::SessionQueueFull));
        // A different conversation is unaffected by the first one's backlog.
        assert!(matches!(scheduler.admit("d", RunClass::Interactive, |_, _| Some(1)), Decision::Run { .. }));
    }

    /// Background capacity is bounded by max + backlog and cannot consume the interactive reserve:
    /// the pick callback is asked for a background worker and told which are claimed.
    #[test]
    fn background_capacity_is_bounded_and_reserved() {
        let scheduler = scheduler();
        // Two background conversations fill `background_max`.
        assert!(matches!(scheduler.admit("bg-1", RunClass::Background, |class, _| { assert_eq!(class, RunClass::Background); Some(1) }), Decision::Run { .. }));
        assert!(matches!(scheduler.admit("bg-2", RunClass::Background, |_, _| Some(2)), Decision::Run { .. }));
        // Two more wait in the backlog.
        assert!(matches!(scheduler.admit("bg-3", RunClass::Background, |_, _| Some(3)), Decision::Run { .. }));
        assert!(matches!(scheduler.admit("bg-4", RunClass::Background, |_, _| Some(4)), Decision::Run { .. }));
        // The fifth exceeds max(2) + backlog(2).
        assert_eq!(scheduler.admit("bg-5", RunClass::Background, |_, _| Some(5)), Decision::Refused(Refusal::BackgroundQueueFull));
        // Interactive is never refused by background saturation.
        assert!(matches!(scheduler.admit("person", RunClass::Interactive, |_, _| Some(0)), Decision::Run { .. }));
    }

    /// The claimed set is handed to the pick callback, so a reserved-but-not-started worker is
    /// not offered to a second conversation.
    #[test]
    fn a_claimed_worker_is_not_offered_again() {
        let scheduler = scheduler();
        scheduler.admit("a", RunClass::Interactive, |_, _| Some(0));
        let seen = std::sync::Mutex::new(None);
        scheduler.admit("b", RunClass::Interactive, |_, claimed| {
            *seen.lock().unwrap() = Some(claimed.clone());
            Some(1)
        });
        let claimed = seen.lock().unwrap().clone().unwrap();
        assert!(claimed.contains(&0), "worker 0 was claimed by conversation a and must not be offered again");
    }

    /// A conversation with no routing session is not serialised against every other anonymous run.
    #[test]
    fn an_empty_conversation_is_not_shared() {
        let scheduler = scheduler();
        assert!(matches!(scheduler.admit("", RunClass::Interactive, |_, _| Some(0)), Decision::Run { .. }));
        assert!(matches!(scheduler.admit("", RunClass::Interactive, |_, _| Some(1)), Decision::Run { .. }));
        assert!(scheduler.snapshot().is_empty());
    }

    /// The marker is one-way: only `background` is honoured, and `interactive` cannot promote.
    #[test]
    fn the_class_marker_can_only_demote() {
        assert_eq!(RunClass::from_header("background"), RunClass::Background);
        assert_eq!(RunClass::from_header(" Background "), RunClass::Background);
        assert_eq!(RunClass::from_header("BACKGROUND"), RunClass::Background);
        assert_eq!(RunClass::from_header("interactive"), RunClass::Interactive);
        assert_eq!(RunClass::from_header(""), RunClass::Interactive);
        assert_eq!(RunClass::from_header("urgent"), RunClass::Interactive);
        // There is no value that returns anything but the default or the demotion.
        assert_eq!(RunClass::from_header("reserved"), RunClass::Interactive);
    }

    /// No pick available for a background run is a refusal, not a fallback into the reserve.
    #[test]
    fn a_background_run_with_no_worker_is_refused() {
        let scheduler = scheduler();
        assert_eq!(
            scheduler.admit("bg", RunClass::Background, |_, _| None),
            Decision::Refused(Refusal::BackgroundQueueFull)
        );
    }

    /// Completion is idempotent-safe: an extra complete for an unknown conversation does nothing.
    #[test]
    fn completing_an_unknown_conversation_is_a_no_op() {
        let scheduler = scheduler();
        scheduler.complete("never-admitted");
        scheduler.admit("c", RunClass::Interactive, |_, _| Some(0));
        scheduler.complete("c");
        scheduler.complete("c");
        assert!(scheduler.snapshot().is_empty());
    }
}
