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
//!     on its own: a protocol directory missing the files intake writes (`intent.json`, `ack.json`,
//!     `binding.json`), which nothing will ever write into a deploy that has passed by. It is *retired* -
//!     renamed into `deploy-protocol-retired/` - after a grace period, so the next tick does not observe it
//!     again, and its evidence is kept rather than deleted. A *runtime* problem (`parent_owner_unavailable`,
//!     a disabled return hook) is retried and never retired: the observation is the thing that would notice it
//!     clearing, and retiring a live deploy's directory would throw its report away to make a log quieter.
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
/// `previous` is what was reported for this id: the problem text and when it was first reported.
/// `structural` says whether the problem is one that cannot clear on its own; only those are retired.
pub(crate) fn verdict(previous: Option<(&str, u64)>, problem: &str, now: u64, grace: u64, structural: bool) -> Verdict {
    match previous {
        // Nothing has been said about this directory: say it once.
        None => Verdict::Report,
        // A changed problem is a changed fact, and a fact nobody is told is a fact nobody can act on.
        Some((said, _)) if said != problem => Verdict::Report,
        // The same sentence again is not evidence; past the grace, a structural one means "stop looking".
        Some((_, first)) if structural && now.saturating_sub(first) >= grace => Verdict::Retire,
        Some(_) => Verdict::Quiet,
    }
}

/// One watcher's view of the lane: what it has already said, by request id.
pub(crate) struct Observations {
    /// id -> (the problem last reported, when it was first reported).
    problems: std::collections::BTreeMap<String, (String, u64)>,
}

impl Observations {
    /// What the last watcher already said, so this one does not say it again.
    pub(crate) fn load() -> Observations {
        let mut problems = std::collections::BTreeMap::new();
        if let Ok(bytes) = std::fs::read(problems_path()) {
            if let Ok(Value::Object(map)) = serde_json::from_slice::<Value>(&bytes) {
                for (id, record) in map {
                    if let (Some(problem), Some(first)) = (record["problem"].as_str(), record["first_seen"].as_u64()) {
                        problems.insert(id, (problem.to_string(), first));
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
            .map(|(id, (problem, first))| (id.clone(), json!({"problem": problem, "first_seen": first})))
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
        // The files intake writes, first: a directory missing one of them cannot be observed at all, and asking
        // anyway is how the io error became the only thing this lane ever said.
        let missing = sentinel_return::missing_observation_files(&dir);
        let (problem, structural) = if !missing.is_empty() {
            (format!("cannot be observed: missing {}", missing.join(", ")), true)
        } else {
            match sentinel_return::observe(id) {
                Ok(()) => {
                    self.forget(id);
                    return;
                }
                Err(error) => (format!("{error:#}"), false),
            }
        };
        let previous = self.problems.get(id).map(|(said, first)| (said.as_str(), *first));
        match verdict(previous, &problem, now, grace_secs(), structural) {
            Verdict::Report => {
                let grace = grace_secs();
                audit(
                    "return-observation-problem",
                    id,
                    &format!("{problem} (said once per request id and problem; a directory missing the files intake writes is retired to {} after {grace}s, a runtime problem is retried)", retired_root().display()),
                );
                self.problems.insert(id.to_string(), (problem, now));
                self.save();
            }
            Verdict::Quiet => {}
            Verdict::Retire => self.retire(id, &problem, now),
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
                let waited = now.saturating_sub(self.problems.get(id).map(|(_, first)| *first).unwrap_or(now));
                audit(
                    "return-observation-retired",
                    id,
                    &format!("{problem}; unchanged for {waited}s, so the directory was retired to {} and is no longer observed (nothing was deleted)", to.display()),
                );
                self.problems.remove(id);
            }
            // A retirement that could not happen is not a new problem: the line already written stands, and the
            // next pass tries again without saying it again.
            Err(why) => {
                audit("return-observation-retire-failed", id, &format!("{problem}; could not be retired ({why}); it stays in the lane and is not re-reported"));
            }
        }
        self.save();
    }

    /// Forget an id that observed cleanly (or no longer exists), so a later problem is reported again.
    pub(crate) fn forget(&mut self, id: &str) {
        if self.problems.remove(id).is_some() {
            self.save();
        }
    }
}
