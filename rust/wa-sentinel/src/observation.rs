//! The watcher's return-observation lane: one line per (request id, problem), then the entry leaves the lane.
//!
//! The concern, measured on `work` (2026-11-18): `sentinel.log` held **523,067** `return-observation-problem`
//! lines over seven days, naming 75 request ids, every one of them with the same text: `No such file or
//! directory (os error 2)`. Each of those protocol directories was a *finished* deploy - a `result.json`
//! saying `ok: true`, dated 11/11 - whose `intent.json`, `ack.json` and `binding.json` had never been
//! written, so the observation could never succeed. The watcher asked again on every tick, the per-id poll
//! backoff turned that into one line a minute per id, and nothing ever stopped: about 108,000 lines a day, for
//! as long as the machine runs. A log like that is not evidence any more - the one line that would matter is
//! buried under the same sentence repeated forever.
//!
//! Two rules, and they differ because the two failures differ:
//!
//!   * **one line per (id, problem)**. The same problem in the same directory is said once; a *changed* problem
//!     is new information and is said again. Nothing in between is written - not a repeat, not a counter, not
//!     a heartbeat;
//!   * **a directory that cannot be observed leaves the lane**. A *structural* problem is one that cannot clear
//!     on its own. What makes a missing file structural is **not that it is missing**: `binding.json` is written
//!     at admit (`deploy_protocol.rs`, `admit`) while `intent.json` and `ack.json` are rewritten on every tick
//!     for a request still in the box, so a deploy held for an hour (a busy node, a protocol that is not ready, a
//!     parent whose owner cannot be read) has `intent.json` and `ack.json` and no binding at all - and that is
//!     healthy, not dead. Measured consequence of the earlier rule ("missing a file intake writes"): a held
//!     protocol deploy was judged structural, retired into `deploy-protocol-retired/` with its evidence after the
//!     grace, recreated by the next intake under the same id, and then *retired into an occupied lane* on every
//!     tick for ever - the same unbounded log this lane exists to remove, in a new sentence. So the structural
//!     test is about what is in flight, not about which file is absent. A directory is structural only when the
//!     id is in neither `requests/` nor `claimed/` (nothing will write into it again) **and** its state does not
//!     say `withdrawn` (a withdrawal still owes the asking session its one return event, and establishing the
//!     binding is how that report reaches it - `main::withdraw_request`). It is *retired* - renamed into
//!     `deploy-protocol-retired/` - after a grace period, so the next tick does not observe it again, and its
//!     evidence is kept rather than deleted. A *runtime* problem (`parent_owner_unavailable`, a disabled
//!     return hook) is retried and never retired: the observation is the thing that would notice it clearing,
//!     and retiring a live deploy's directory would throw its report away to make a log quieter;
//!   * **a retirement that could not happen is said once**. The retired lane refuses to overwrite evidence, so an
//!     id already retired cannot be retired again - and a rule that kept answering "retire" wrote
//!     `return-observation-retire-failed` on every tick, which is the first defect one lane over. The failure is
//!     remembered with the problem, and that id stays quiet until the problem itself changes.
//!
//! What is remembered is on disk (`observation-problems.json`), because the defect this fixes must not come
//! back on the next restart: a watcher restarted every minute would otherwise re-report every stale directory
//! every minute, which is the same mistake at a lower rate.

use super::*;

/// Where the lane keeps what it has already said, so a restart does not say it again.
fn problems_path() -> PathBuf {
    sentinel_dir().join("observation-problems.json")
}

/// Where a protocol directory that cannot be observed is retired to. A lane of its own and not a deletion: the
/// directory is evidence (a deploy's `result.json` lives in it), and "we stopped looking" must never mean "we
/// threw away what we saw".
pub(crate) fn retired_root() -> PathBuf {
    sentinel_dir().join("deploy-protocol-retired")
}

/// How long a directory may stay structurally unobservable before it is retired. Generous on purpose: those
/// files are written within milliseconds of the directory being created, so anything still missing after
/// minutes was never going to appear. `WASM_SENTINEL_OBSERVE_GRACE` overrides it, which is what a proof uses
/// instead of waiting.
pub(crate) fn grace_secs() -> u64 {
    std::env::var("WASM_SENTINEL_OBSERVE_GRACE")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .unwrap_or(300)
}

/// What the lane remembers about one request id: the problem it last reported, when it first reported it, and
/// whether it already tried to retire the directory and could not. The last flag is what makes a failed
/// retirement a *settled* fact rather than a per-tick line: [`verdict`] cannot answer `Retire` again for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Said {
    /// The problem text, verbatim, as it was last reported.
    pub(crate) problem: String,
    /// When that problem was first reported: the clock the grace is measured from.
    pub(crate) first_seen: u64,
    /// The directory was retired and the move failed (the retired lane already holds this id).
    pub(crate) retire_failed: bool,
}

impl Said {
    pub(crate) fn reported(problem: &str, at: u64) -> Said {
        Said { problem: problem.to_string(), first_seen: at, retire_failed: false }
    }
}

/// What the lane must do about one directory, given what it said last time.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Verdict {
    /// New information: one audit line, and the clock starts (or restarts) here.
    Report,
    /// The same problem again: nothing at all is written.
    Quiet,
    /// The same structural problem, unchanged, past the grace: the directory leaves the lane.
    Retire,
}

/// The rule of the lane, as a function of what was recorded and what was just seen - readable and testable
/// without a watcher and without a clock.
///
/// `previous` is what was reported for this id: the problem text, when it was first reported, and whether a
/// retirement already failed. `structural` says whether the problem is one that cannot clear on its own; only
/// those are retired, and only until the retirement itself has been proved impossible.
pub(crate) fn verdict(previous: Option<&Said>, problem: &str, now: u64, grace: u64, structural: bool) -> Verdict {
    match previous {
        // Nothing has been said about this directory: say it once.
        None => Verdict::Report,
        // A changed problem is a changed fact, and a fact nobody is told is a fact nobody can act on.
        Some(said) if said.problem != problem => Verdict::Report,
        // A retirement that already failed is settled, however long the same problem persists: asking again is
        // the same question, and the answer (the retired lane holds this id) cannot change by itself.
        Some(said) if said.retire_failed => Verdict::Quiet,
        // The same sentence again is not evidence; past the grace, a structural one means "stop looking".
        Some(said) if structural && now.saturating_sub(said.first_seen) >= grace => Verdict::Retire,
        Some(_) => Verdict::Quiet,
    }
}

/// One watcher's view of the lane: what it has already said, by request id.
pub(crate) struct Observations {
    /// id -> what was said about it (the problem, when, and whether a retirement already failed).
    problems: std::collections::BTreeMap<String, Said>,
}

impl Observations {
    /// What the last watcher already said, so this one does not say it again.
    pub(crate) fn load() -> Observations {
        let mut problems = std::collections::BTreeMap::new();
        if let Ok(bytes) = std::fs::read(problems_path()) {
            if let Ok(Value::Object(map)) = serde_json::from_slice::<Value>(&bytes) {
                for (id, record) in map {
                    if let (Some(problem), Some(first)) = (record["problem"].as_str(), record["first_seen"].as_u64()) {
                        // A record written before a retirement could fail carries no flag; absence is "not tried".
                        let retire_failed = record["retire_failed"] == true;
                        problems.insert(id, Said { problem: problem.to_string(), first_seen: first, retire_failed });
                    }
                }
            }
        }
        Observations { problems }
    }

    /// The record on disk. A lane that cannot write its memory is a lane that reports again after a restart -
    /// worse than a missing record, and never a reason to stop observing.
    fn save(&self) {
        let map: serde_json::Map<String, Value> = self
            .problems
            .iter()
            .map(|(id, said)| {
                (id.clone(), json!({"problem": said.problem, "first_seen": said.first_seen, "retire_failed": said.retire_failed}))
            })
            .collect();
        let _ = wa_operation::atomic_json(&problems_path(), &Value::Object(map));
    }

    /// One pass over the protocol directories, which is what the watcher does on each tick.
    pub(crate) fn pass(&mut self) {
        let root = sentinel_dir().join("deploy-protocol");
        let Ok(listing) = std::fs::read_dir(&root) else { return };
        let mut ids: Vec<String> = listing
            .flatten()
            .filter(|entry| entry.path().is_dir())
            .filter_map(|entry| entry.file_name().to_str().map(str::to_string))
            .collect();
        // Sorted, so two runs over the same directories write the same lines in the same order.
        ids.sort();
        let now = now_epoch();
        for id in &ids {
            if stop_path().exists() || service_stopping() {
                return;
            }
            self.observe(id, now);
        }
        // A directory that is gone is forgotten here, not lazily inside `observe`: it is never observed again,
        // so a line kept for it would make a later request with the same id inherit a silence it did not earn.
        let before = self.problems.len();
        self.problems.retain(|id, _| ids.contains(id));
        if self.problems.len() != before {
            self.save();
        }
    }

    /// Observe one directory, and say at most one new thing about it.
    pub(crate) fn observe(&mut self, id: &str, now: u64) {
        let dir = sentinel_dir().join("deploy-protocol").join(id);
        if !dir.is_dir() {
            // The directory is gone: so is the problem. Keeping its line on disk would make a later request
            // with this id inherit a silence it did not earn.
            self.forget(id);
            return;
        }
        // The files intake and admit write, first: a directory missing one of them cannot be observed at all, and
        // asking anyway is how the io error became the only thing this lane ever said.
        let missing = sentinel_return::missing_observation_files(&dir);
        // ...but a missing file is only evidence when nothing is going to write it. Two things can still write
        // into this directory: the queue holding the request (intake rewrites intent/ack every tick, admit writes
        // the binding), and a withdrawal that still owes the asking session its return event.
        let in_flight = Self::in_the_box(id);
        let owed = Self::owes_a_report(&dir);
        let (problem, structural) = if !missing.is_empty() && !owed {
            // The line says what is missing; whether it is structural is decided by whether anything is still
            // coming. A held deploy is one line, once, and it keeps its directory however long it is held.
            (format!("cannot be observed: missing {}", missing.join(", ")), !in_flight)
        } else {
            // The engine keeps its own schedule, and says nothing while a directory is deferred. A deferral is not
            // an observation: forgetting here would make the next real attempt report the same problem again, which
            // is this lane's defect at a term's length instead of a tick's.
            if !sentinel_return::due(id, now) {
                return;
            }
            match sentinel_return::observe(id) {
                Ok(()) => {
                    self.forget(id);
                    return;
                }
                Err(error) => (format!("{error:#}"), false),
            }
        };
        let previous = self.problems.get(id);
        match verdict(previous, &problem, now, grace_secs(), structural) {
            Verdict::Report => {
                let grace = grace_secs();
                audit(
                    "return-observation-problem",
                    id,
                    &format!("{problem} (said once per request id and problem; a directory no request in the queue will fill, and that owes no report, is retired to {} after {grace}s; a runtime problem and a held deploy are retried and never retired)", retired_root().display()),
                );
                self.problems.insert(id.to_string(), Said::reported(&problem, now));
                self.save();
            }
            Verdict::Quiet => {}
            Verdict::Retire => {
                // A REQUEST A SPAWNED INSTALLER NEVER FINISHED IS NOT A DIRECTORY TO RETIRE (23/11, G blocker).
                // MEASURED: ffd2a0a5's installer refused the install and wrote none of the protocol files, so this
                // lane retired the directory as unobservable - and the request ended nowhere: not installed, not
                // failed, not re-queued, and the box said `0 waiting`. The installer's own three files answer it.
                match installer_outcome::verdict(id) {
                    Some(installer_outcome::Outcome::Uninstalled(why)) => {
                        match installer_outcome::fail_unobserved(id, &why) {
                            Ok(true) => audit("return-observation-failed", id,
                                &format!("{problem}; the installer ended and nothing was installed, so the request failed with its own reason and was re-queued once (no retirement)")),
                            Ok(false) => {}
                            Err(error) => audit("return-observation-failed", id, &format!("{problem}; could not record the installer's failure: {error:#}")),
                        }
                        self.forget(id);
                        return;
                    }
                    // Still running: a live installer is neither a retirement nor a silence - the watchdog and the
                    // installer's own progress record already speak for it.
                    Some(installer_outcome::Outcome::Running) => return,
                    Some(installer_outcome::Outcome::Installed) | None => {}
                }
                self.retire(id, &problem, now)
            }
        }
    }

    /// Stop observing this id. The directory is *moved*, not removed: what it holds is evidence, and the lane
    /// only gives up the claim that it can be observed.
    fn retire(&mut self, id: &str, problem: &str, now: u64) {
        let from = sentinel_dir().join("deploy-protocol").join(id);
        let to = retired_root().join(id);
        let moved = if to.exists() {
            Err(format!("{} already exists, and evidence is never overwritten", to.display()))
        } else {
            std::fs::create_dir_all(retired_root())
                .map_err(|error| format!("{error}"))
                .and_then(|()| std::fs::rename(&from, &to).map_err(|error| format!("{error}")))
        };
        match moved {
            Ok(()) => {
                let waited = now.saturating_sub(self.problems.get(id).map(|said| said.first_seen).unwrap_or(now));
                audit(
                    "return-observation-retired",
                    id,
                    &format!("{problem}; unchanged for {waited}s, so the directory was retired to {} and is no longer observed (nothing was deleted)", to.display()),
                );
                self.problems.remove(id);
            }
            // A retirement that could not happen is not a new problem: the line already written stands, and the
            // failure is remembered so this id is quiet - not retried and re-reported on every tick, which is the
            // same unbounded log one lane over. A *changed* problem resets it: that is a new fact, and the retry
            // that decides whether the new one can be retired is worth one line.
            Err(why) => {
                audit(
                    "return-observation-retire-failed",
                    id,
                    &format!("{problem}; could not be retired ({why}); it stays in the lane, is not re-reported, and no further retirement is attempted while this problem stands"),
                );
                self.problems.insert(id.to_string(), Said {
                    problem: problem.to_string(),
                    first_seen: self.problems.get(id).map(|said| said.first_seen).unwrap_or(now),
                    retire_failed: true,
                });
            }
        }
        self.save();
    }

    /// Whether the queue still holds this request: requests/ (waiting to be dispatched) or claimed/ (being
    /// performed). Read from the box itself, which is the only thing that knows - a directory's own files cannot
    /// say whether more are coming.
    fn in_the_box(id: &str) -> bool {
        ["requests", "claimed"]
            .iter()
            .any(|lane| sentinel_dir().join(lane).join(format!("{id}.json")).exists())
    }

    /// Whether this directory still owes its parent a report, which is what a withdrawn protocol deploy is: the
    /// withdrawal is recorded as the state phase, and the observation that follows is what establishes the
    /// binding admit never wrote and delivers the one event the asking session is waiting for.
    fn owes_a_report(dir: &Path) -> bool {
        std::fs::read(dir.join("state.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .is_some_and(|state| state["phase"] == "withdrawn")
    }

    /// Forget an id that observed cleanly (or no longer exists), so a later problem is reported again.
    pub(crate) fn forget(&mut self, id: &str) {
        if self.problems.remove(id).is_some() {
            self.save();
        }
    }
}
