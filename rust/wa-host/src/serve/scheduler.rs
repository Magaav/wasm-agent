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
//!    run may do and who may cancel it; the conversation decides what it may write and
//!    therefore what serialises. They travel separately, and ownership is on the conversation.
//! 3. **Interactive capacity is reserved.** A background run may not use an interactive
//!    worker, so a flood of background work cannot take the worker a person's next run needs.
//!    Background runs are additionally bounded in both concurrency and backlog, and a
//!    conversation's own backlog is bounded so one conversation cannot fill a worker's queue.
//!
//! Each admitted run also carries a **cancel flag of its own**. The flag is per-run, not
//! per-conversation, so cancelling a running run cannot also cancel the run queued behind it.
//! The flag is a request: a run is reported `cancelled` only when it actually settles.
//!
//! The class marker is deliberately one-way. `X-WA-Run-Class: background` demotes a run into
//! the background lane. Any other value, including `interactive`, is ignored: no request
//! header grants reserved capacity, so an untrusted caller cannot promote itself. Relayed
//! peer runs are classified background by the node itself, never by a header.
//!
//! The module is pure policy over an abstract "pick a worker" callback, so the ordering and
//! capacity rules are unit-testable without sockets or an interpreter.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use crate::subagents::SocketSlot;

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

/// The lifecycle of an admitted run, as a caller sees it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RunState {
    /// Admitted, waiting for its worker.
    Queued,
    /// Executing.
    Running,
    /// Cancellation was requested and the run has settled.
    Cancelled,
    /// Finished on its own.
    Completed,
}

impl RunState {
    pub fn as_str(self) -> &'static str {
        match self {
            RunState::Queued => "queued",
            RunState::Running => "running",
            RunState::Cancelled => "cancelled",
            RunState::Completed => "completed",
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

/// What admission decided. `cancel` is the run's own flag; the worker installs it as the
/// current-run context so the provider reader can observe a cancellation request. `sockets`
/// is the run's own slot: the worker binds it while the run executes and the accept thread
/// shuts exactly these sockets down when it cancels this run, never the next queued one's.
#[derive(Debug)]
pub enum Decision {
    /// Run on this worker. The conversation is now owned by it until `complete_run`.
    Run { run_id: u64, worker: usize, cancel: Arc<AtomicBool>, sockets: SocketSlot },
    /// The conversation is owned by this worker; queue behind it there.
    Behind { run_id: u64, worker: usize, cancel: Arc<AtomicBool>, sockets: SocketSlot },
    /// No room. The caller replies 503 and admits nothing.
    Refused(Refusal),
}

/// The outcome of a cancel request, scoped to the authenticated owner.
#[derive(Debug, PartialEq)]
pub enum CancelOutcome {
    /// The flag was set. `state` is the run's state *before* it settles: the caller must poll
    /// `status` until it becomes `cancelled` or `completed`, because a request is not a stop.
    Requested { run_id: u64, state: RunState },
    /// No such run for this owner and conversation.
    NotFound,
    /// The run exists but belongs to another owner.
    Forbidden,
}

/// A run as `/runs status` reports it: no prompts, no credentials, just identity and lifecycle.
#[derive(Clone, Debug, PartialEq)]
pub struct RunView {
    pub run_id: u64,
    pub state: RunState,
    pub cancel_requested: bool,
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

struct RunRecord {
    owner: String,
    conversation: String,
    class: RunClass,
    cancel: Arc<AtomicBool>,
    sockets: SocketSlot,
    state: RunState,
}

#[derive(Default)]
struct Inner {
    owners: HashMap<String, Owner>,
    runs: HashMap<u64, RunRecord>,
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
    pub fn admit<F>(&self, conversation: &str, owner: &str, class: RunClass, pick: F) -> Decision
    where
        F: FnOnce(RunClass, &HashSet<usize>) -> Option<usize>,
    {
        let mut inner = self.inner.lock().unwrap_or_else(|poison| poison.into_inner());
        inner.next_run_id = inner.next_run_id.wrapping_add(1);
        let run_id = inner.next_run_id;
        let cancel = Arc::new(AtomicBool::new(false));
        // The run's own socket slot lives from admission through settlement, so a cancel on the
        // accept thread can wake this run's silent provider read without touching the queued run
        // behind it (whose slot is a different Arc).
        let sockets: SocketSlot = Arc::new(Mutex::new(Vec::new()));

        let record = |owner: &str, conversation: &str, class: RunClass, cancel: &Arc<AtomicBool>,
                      sockets: &SocketSlot| RunRecord {
            owner: owner.to_string(),
            conversation: conversation.to_string(),
            class,
            cancel: cancel.clone(),
            sockets: sockets.clone(),
            state: RunState::Queued,
        };

        // 1. Same conversation: queue behind its owner. This is the whole of same-session ordering.
        if !conversation.is_empty() {
            if let Some(owner_record) = inner.owners.get_mut(conversation) {
                if owner_record.pending >= self.config.session_queue_depth {
                    return Decision::Refused(Refusal::SessionQueueFull);
                }
                owner_record.pending += 1;
                let worker = owner_record.worker;
                inner.runs.insert(run_id, record(owner, conversation, class, &cancel, &sockets));
                return Decision::Behind { run_id, worker, cancel, sockets };
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
        inner.runs.insert(run_id, record(owner, conversation, class, &cancel, &sockets));
        Decision::Run { run_id, worker, cancel, sockets }
    }

    /// The worker picked the run up and is about to execute it.
    pub fn mark_running(&self, run_id: u64) {
        let mut inner = self.inner.lock().unwrap_or_else(|poison| poison.into_inner());
        if let Some(record) = inner.runs.get_mut(&run_id) {
            if record.state == RunState::Queued {
                record.state = RunState::Running;
            }
        }
    }

    /// A run settled. If cancellation was requested, it settles as `cancelled`, not `completed` -
    /// the state is only ever reported after the run actually stopped.
    pub fn complete_run(&self, run_id: u64) {
        let mut inner = self.inner.lock().unwrap_or_else(|poison| poison.into_inner());
        let Some(record) = inner.runs.get_mut(&run_id) else { return };
        let conversation = record.conversation.clone();
        record.state = if record.cancel.load(Ordering::SeqCst) { RunState::Cancelled } else { RunState::Completed };
        if let Some(owner) = inner.owners.get_mut(&conversation) {
            owner.pending = owner.pending.saturating_sub(1);
            if owner.pending == 0 {
                inner.owners.remove(&conversation);
            }
        }
        // Keep the last few settled runs per conversation so `status` can report them, without
        // letting the table grow for the life of the process.
        let mut settled: Vec<u64> = inner
            .runs
            .iter()
            .filter(|(_, record)| {
                record.conversation == conversation
                    && matches!(record.state, RunState::Cancelled | RunState::Completed)
            })
            .map(|(id, _)| *id)
            .collect();
        settled.sort_unstable();
        for stale in settled.iter().rev().skip(4) {
            inner.runs.remove(stale);
        }
    }

    /// Request cancellation of one run, or of the current run for a conversation. Owner-scoped:
    /// a caller can never cancel a run that belongs to someone else. The flag is set on one run
    /// only, so the run queued behind it is untouched.
    pub fn cancel_run(&self, owner: &str, conversation: &str, run_id: Option<u64>) -> CancelOutcome {
        let mut inner = self.inner.lock().unwrap_or_else(|poison| poison.into_inner());
        let target = match run_id {
            Some(id) => match inner.runs.get(&id) {
                Some(record) if record.conversation == conversation => Some(id),
                Some(_) => return CancelOutcome::NotFound,
                None => return CancelOutcome::NotFound,
            },
            None => {
                let mut running = None;
                let mut queued = None;
                for (id, record) in inner.runs.iter() {
                    if record.conversation != conversation || record.owner != owner {
                        continue;
                    }
                    match record.state {
                        RunState::Running if running.is_none() || *id < running.unwrap() => running = Some(*id),
                        RunState::Queued if queued.is_none() || *id < queued.unwrap() => queued = Some(*id),
                        _ => {}
                    }
                }
                running.or(queued)
            }
        };
        let Some(id) = target else { return CancelOutcome::NotFound };
        let record = inner.runs.get_mut(&id).expect("target run exists");
        if record.owner != owner {
            return CancelOutcome::Forbidden;
        }
        record.cancel.store(true, Ordering::SeqCst);
        // Wake a read that is producing nothing. This is the run's own slot, so a later cancel can
        // never shut down the socket of the run queued behind this one.
        crate::subagents::shutdown_sockets(&record.sockets);
        CancelOutcome::Requested { run_id: id, state: record.state }
    }

    /// The runs of one conversation, as seen by their owner. A caller only ever sees its own.
    pub fn runs_for(&self, owner: &str, conversation: &str) -> Vec<RunView> {
        let inner = self.inner.lock().unwrap_or_else(|poison| poison.into_inner());
        let mut views: Vec<RunView> = inner
            .runs
            .iter()
            .filter(|(_, record)| record.conversation == conversation && record.owner == owner)
            .map(|(id, record)| RunView {
                run_id: *id,
                state: record.state,
                cancel_requested: record.cancel.load(Ordering::SeqCst),
            })
            .collect();
        views.sort_by_key(|view| view.run_id);
        views
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

    /// The active run ids per conversation, for `/health`'s `run_ids`. No prompts, no credentials.
    pub fn run_ids(&self) -> Vec<(String, u64, RunState)> {
        let inner = self.inner.lock().unwrap_or_else(|poison| poison.into_inner());
        let mut rows: Vec<_> = inner
            .runs
            .iter()
            .map(|(id, record)| (record.conversation.clone(), *id, record.state))
            .collect();
        rows.sort_by_key(|(_, id, _)| *id);
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

pub fn admit(
    conversation: &str,
    owner: &str,
    class: RunClass,
    pick: impl FnOnce(RunClass, &HashSet<usize>) -> Option<usize>,
) -> Decision {
    match global() {
        Some(scheduler) => scheduler.admit(conversation, owner, class, pick),
        // Before `run()` installs the scheduler (unit tests that never serve), every run is
        // unrouted and goes to worker 0, exactly as a single-interpreter node did.
        None => Decision::Run {
            run_id: 0,
            worker: 0,
            cancel: Arc::new(AtomicBool::new(false)),
            sockets: Arc::new(Mutex::new(Vec::new())),
        },
    }
}

pub fn mark_running(run_id: u64) {
    if let Some(scheduler) = global() {
        scheduler.mark_running(run_id);
    }
}

pub fn complete_run(run_id: u64) {
    if let Some(scheduler) = global() {
        scheduler.complete_run(run_id);
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
        let first = scheduler.admit("conversation-a", "master", RunClass::Interactive, |_, _| Some(0));
        assert!(matches!(first, Decision::Run { worker: 0, .. }));
        let second = scheduler.admit("conversation-a", "master", RunClass::Interactive, |_, _| Some(1));
        match second {
            Decision::Behind { worker, .. } => assert_eq!(worker, 0, "the second run must follow its owner, not a fresh worker"),
            other => panic!("expected Behind, got {other:?}"),
        }
        // The pick closure is never consulted while the conversation is owned.
        let third = scheduler.admit("conversation-a", "master", RunClass::Interactive, |_, _| panic!("must not pick"));
        assert!(matches!(third, Decision::Behind { worker: 0, .. }));
    }

    /// Completion frees the conversation, and the next run may land elsewhere.
    #[test]
    fn completion_releases_ownership() {
        let scheduler = scheduler();
        let decision = scheduler.admit("conversation-a", "master", RunClass::Interactive, |_, _| Some(0));
        let run_id = match decision { Decision::Run { run_id, .. } => run_id, _ => unreachable!() };
        scheduler.complete_run(run_id);
        let next = scheduler.admit("conversation-a", "master", RunClass::Interactive, |_, _| Some(2));
        assert!(matches!(next, Decision::Run { worker: 2, .. }));
    }

    /// A conversation's backlog is bounded; the run that exceeds it is refused, not queued forever.
    #[test]
    fn a_conversations_backlog_is_bounded() {
        let scheduler = scheduler();
        scheduler.admit("c", "master", RunClass::Interactive, |_, _| Some(0));
        scheduler.admit("c", "master", RunClass::Interactive, |_, _| None); // behind, pending 2
        scheduler.admit("c", "master", RunClass::Interactive, |_, _| None); // behind, pending 3 == depth
        assert!(matches!(scheduler.admit("c", "master", RunClass::Interactive, |_, _| None), Decision::Refused(Refusal::SessionQueueFull)));
        // A different conversation is unaffected by the first one's backlog.
        assert!(matches!(scheduler.admit("d", "master", RunClass::Interactive, |_, _| Some(1)), Decision::Run { .. }));
    }

    /// Background capacity is bounded by max + backlog and cannot consume the interactive reserve:
    /// the pick callback is asked for a background worker and told which are claimed.
    #[test]
    fn background_capacity_is_bounded_and_reserved() {
        let scheduler = scheduler();
        assert!(matches!(scheduler.admit("bg-1", "master", RunClass::Background, |class, _| { assert_eq!(class, RunClass::Background); Some(1) }), Decision::Run { .. }));
        assert!(matches!(scheduler.admit("bg-2", "master", RunClass::Background, |_, _| Some(2)), Decision::Run { .. }));
        assert!(matches!(scheduler.admit("bg-3", "master", RunClass::Background, |_, _| Some(3)), Decision::Run { .. }));
        assert!(matches!(scheduler.admit("bg-4", "master", RunClass::Background, |_, _| Some(4)), Decision::Run { .. }));
        assert!(matches!(scheduler.admit("bg-5", "master", RunClass::Background, |_, _| Some(5)), Decision::Refused(Refusal::BackgroundQueueFull)));
        // Interactive is never refused by background saturation.
        assert!(matches!(scheduler.admit("person", "master", RunClass::Interactive, |_, _| Some(0)), Decision::Run { .. }));
    }

    /// The claimed set is handed to the pick callback, so a reserved-but-not-started worker is
    /// not offered to a second conversation.
    #[test]
    fn a_claimed_worker_is_not_offered_again() {
        let scheduler = scheduler();
        scheduler.admit("a", "master", RunClass::Interactive, |_, _| Some(0));
        let seen = std::sync::Mutex::new(None);
        scheduler.admit("b", "master", RunClass::Interactive, |_, claimed| {
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
        assert!(matches!(scheduler.admit("", "master", RunClass::Interactive, |_, _| Some(0)), Decision::Run { .. }));
        assert!(matches!(scheduler.admit("", "master", RunClass::Interactive, |_, _| Some(1)), Decision::Run { .. }));
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
        assert_eq!(RunClass::from_header("reserved"), RunClass::Interactive);
    }

    /// No pick available for a background run is a refusal, not a fallback into the reserve.
    #[test]
    fn a_background_run_with_no_worker_is_refused() {
        let scheduler = scheduler();
        assert!(matches!(
            scheduler.admit("bg", "master", RunClass::Background, |_, _| None),
            Decision::Refused(Refusal::BackgroundQueueFull)
        ));
    }

    /// Completing an unknown run is a no-op, and a double complete does not double-release.
    #[test]
    fn completing_an_unknown_run_is_a_no_op() {
        let scheduler = scheduler();
        scheduler.complete_run(999);
        let decision = scheduler.admit("c", "master", RunClass::Interactive, |_, _| Some(0));
        let run_id = match decision { Decision::Run { run_id, .. } => run_id, _ => unreachable!() };
        scheduler.complete_run(run_id);
        scheduler.complete_run(run_id);
        assert!(scheduler.snapshot().is_empty());
    }

    /// Cancelling one run must not touch the run queued behind it: the flags are per-run.
    #[test]
    fn a_cancel_flag_is_per_run_not_per_conversation() {
        let scheduler = scheduler();
        let first = scheduler.admit("c", "master", RunClass::Interactive, |_, _| Some(0));
        let (first_id, first_flag) = match first { Decision::Run { run_id, cancel, .. } => (run_id, cancel), _ => unreachable!() };
        let second = scheduler.admit("c", "master", RunClass::Interactive, |_, _| None);
        let second_flag = match second { Decision::Behind { cancel, .. } => cancel, _ => unreachable!() };
        assert_eq!(scheduler.cancel_run("master", "c", Some(first_id)), CancelOutcome::Requested { run_id: first_id, state: RunState::Queued });
        assert!(first_flag.load(Ordering::SeqCst), "the cancelled run's flag is set");
        assert!(!second_flag.load(Ordering::SeqCst), "the queued run behind it is untouched");
        scheduler.mark_running(first_id);
        scheduler.complete_run(first_id);
        // The cancelled run settles as cancelled; the queued run still completes normally.
        let views = scheduler.runs_for("master", "c");
        assert_eq!(views[0].state, RunState::Cancelled);
        assert_eq!(views[1].state, RunState::Queued);
    }

    /// Owner scoping: another user cannot cancel this run.
    #[test]
    fn a_foreign_owner_cannot_cancel() {
        let scheduler = scheduler();
        let decision = scheduler.admit("c", "master", RunClass::Interactive, |_, _| Some(0));
        let run_id = match decision { Decision::Run { run_id, .. } => run_id, _ => unreachable!() };
        assert_eq!(scheduler.cancel_run("guest", "c", Some(run_id)), CancelOutcome::Forbidden);
        assert_eq!(scheduler.cancel_run("guest", "c", None), CancelOutcome::NotFound);
        assert_eq!(scheduler.cancel_run("master", "c", Some(run_id)), CancelOutcome::Requested { run_id, state: RunState::Queued });
    }

    /// A cancel without a run id targets the running run, else the oldest queued one, and never
    /// reports `cancelled` before the run settles.
    #[test]
    fn cancel_without_a_run_id_targets_the_current_run() {
        let scheduler = scheduler();
        let first = match scheduler.admit("c", "master", RunClass::Interactive, |_, _| Some(0)) { Decision::Run { run_id, .. } => run_id, _ => unreachable!() };
        let second = match scheduler.admit("c", "master", RunClass::Interactive, |_, _| None) { Decision::Behind { run_id, .. } => run_id, _ => unreachable!() };
        scheduler.mark_running(first);
        let outcome = scheduler.cancel_run("master", "c", None);
        assert_eq!(outcome, CancelOutcome::Requested { run_id: first, state: RunState::Running });
        // Before it settles, status still says running with a cancel request - not cancelled.
        let views = scheduler.runs_for("master", "c");
        assert_eq!(views[0].state, RunState::Running);
        assert!(views[0].cancel_requested);
        assert_eq!(views[1].run_id, second);
        assert!(!views[1].cancel_requested);
        scheduler.complete_run(first);
        assert_eq!(scheduler.runs_for("master", "c")[0].state, RunState::Cancelled);
    }
}
