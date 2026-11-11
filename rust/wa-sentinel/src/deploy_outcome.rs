//! One deploy, one report. Durably.
//!
//! The concern, in the words it was measured in (2026-11-10, session `b5a92f25`): three deploys were
//! requested on purpose and the session ended its turn each time so the sentinel could install. After 06:39
//! and 07:09 a `[Sentinel notice]` woke it. After the 07:14 retry nothing ever did: the session sat idle for
//! one hour and forty-five minutes until a human wrote again.
//!
//! What the records said, when they were read back:
//!
//!   * the 07:09:37 deploy (`sentinel/done/1794305337796210000-…`) carried **no session** at all - its
//!     detail reads "no continuation was requested (no --session)" - and it *succeeded* at 07:15:11. The
//!     only code that could have woken anybody was `deploy.sh`'s last lines, and they are guarded by
//!     `if [ -n "$SESSION" ]`. There was nobody to tell, and nothing that noticed;
//!   * the 07:14:07 retry (`request run --script scripts/deploy.sh`) had no session either, and was refused
//!     within a second by the script allowlist (`sentinel/failed/1794305647073540900-…`). The run door
//!     reported the failure into a directory no session reads.
//!
//! The defect is not that one installer died. It is that **the completion signal of a deploy was owned by
//! the process that performs the swap**, which is the one process that is killed by it - the node is
//! stopped, the binary is replaced, the watcher is restarted, and `deploy.sh` may be gone before its
//! continuation block runs. Nothing on disk bound the deploy to the session that asked for it, so nothing
//! else could report, and `finish_request` had already recorded the request as `done`/`spawned` at spawn
//! time: to the queue, the deploy was finished before it had installed anything.
//!
//! This module is the missing durable half. At request time it writes one small record - which session, which
//! prompt, what was asked, when - into `sentinel/deploy-outcome/<request id>.json`. Whichever terminal event
//! survives settles it **exactly once**, by queuing a single `wake` request under a deterministic key:
//!
//!   * the sentinel's own wait on the installer it spawned (`watch_deploy_exit`), for a deploy that runs to
//!     its end - success or failure, with the exit status;
//!   * `deploy-result.json`, which `deploy.sh` writes on both sides of the swap, matched by the request id
//!     the sentinel now passes it: the installer's own words come back even when the sentinel that spawned
//!     it is gone;
//!   * the watchdog in the watcher loop and at watcher start: a deploy whose outcome has not reached the
//!     session within [`timeout_secs`] is reported **silent**, carrying what is known - the deploy id, the
//!     last step the queue recorded, the installer's pid and whether it is still alive, and the commit
//!     `installed.txt` names.
//!
//! Every input is a file, so the guarantee survives the node being replaced and the sentinel restarting: the
//! next watcher reads the record and reports what the previous one could not. The notice itself goes through
//! the request box, which is already retried by whichever watcher is alive and already refuses to replay a
//! wake whose outcome is unknown.
//!
//! Scope, stated so it is not overclaimed: this covers the legacy `request deploy` door and only that. A
//! protocol deploy (one carrying `--expected-sha`) is admitted only when its own return engine is enabled
//! (`deploy_protocol::ready`), and that engine - `sentinel_return` plus the `onSentinelReturn` job - owns its
//! parent's report. Two owners for one deploy would break "exactly one notice", so `open` is never called for
//! one. An installer named through the `run` door is refused at request time instead (`main::request`),
//! because that door reports the *script's* result and a deploy's result is a node replacement.

use super::*;

/// How long a deploy may stay unreported before the watchdog says so.
///
/// Not a guess: the deploys measured on this node on 2026-11-10 took 1m30s, 1m37s, 2m16s, 2m18s, 3m48s and
/// 5m29s from spawn to `installed.txt` - the worst of them including a 3m30s wait for the node to go idle
/// inside the deploy itself. Fifteen minutes is a little under three times that worst case, and it is two
/// orders of magnitude below the silence this module exists to end (1h45m). `WA_SENTINEL_DEPLOY_TIMEOUT`
/// overrides it for a machine whose builds are slower than this one; a proof that wants to watch the
/// watchdog rather than the installer can set it lower.
pub(crate) fn timeout_secs() -> u64 {
    std::env::var("WA_SENTINEL_DEPLOY_TIMEOUT")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(900)
}

pub(crate) fn dir() -> PathBuf {
    let dir = sentinel_dir().join("deploy-outcome");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// Request ids are `<epoch-nanos>-<pid>-<sequence>`; anything else cannot name a record file.
fn record_path(id: &str) -> Option<PathBuf> {
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        return None;
    }
    Some(dir().join(format!("{id}.json")))
}

pub(crate) fn read(id: &str) -> Option<Value> {
    let path = record_path(id)?;
    std::fs::read(&path).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok())
}

fn clip(text: &str, limit: usize) -> String {
    text.chars().take(limit).collect()
}

/// Where the install record lives: beside the installed binary, the same place `installed.txt` is written.
fn install_dir() -> PathBuf {
    installed_binary().parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."))
}

/// The commit `installed.txt` names, or a sentence saying why it names none. Read at report time, never
/// cached: the notice is evidence, and evidence about what is installed is only worth reading if it was read
/// just now.
fn installed_commit() -> String {
    let path = install_dir().join("installed.txt");
    match std::fs::read_to_string(&path) {
        Ok(text) => text
            .lines()
            .find_map(|line| line.strip_prefix("commit="))
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| format!("{} names no commit", path.display())),
        Err(_) => format!("no install record at {}", path.display()),
    }
}

/// The installer's own phase record, written by `scripts/upgrade.sh` beside the binary.
///
/// Why this exists: the watchdog's deadline is measured from the installer's start, and a deploy that is
/// waiting for the node to go idle is *working as designed*, not silent. Measured on wasm_the_first
/// (2026-11-10): a deploy waited 14 and 37 minutes for long sessions, the 900 s deadline expired in the
/// middle of the wait, and the session was told the deploy was silent while it was only waiting - the
/// false notice this function removes. `waiting_for_idle` is a named state with its own bound
/// (`WA_DEPLOY_IDLE_BOUND`, written into the record), so the watchdog waits that much longer and, if
/// even the bound is exceeded, reports the state by name instead of calling it silence.
fn installer_phase() -> Option<(String, Option<u64>)> {
    let text = std::fs::read_to_string(install_dir().join("deploy-state.json")).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    let state = value.get("state")?.as_str()?.to_string();
    let bound = value.get("bound_seconds").and_then(Value::as_u64);
    Some((state, bound))
}

/// The installer's own verdict for this deploy, if it got far enough to write one.
///
/// Two places, both attributable to one id: the per-request copy `deploy.sh` makes when it is given
/// `--request-id` (`deploy-protocol/<id>/result.json`), and the shared `<install>/deploy-result.json`, which
/// is only this deploy's if its `request_id` field says so. Anything else is another deploy's result and is
/// ignored - the failure mode of guessing here is reporting a previous deploy's success as this one's.
fn installer_result(id: &str) -> Option<(bool, String, PathBuf)> {
    let mut candidates = vec![sentinel_dir().join("deploy-protocol").join(id).join("result.json")];
    candidates.push(install_dir().join("deploy-result.json"));
    for (index, path) in candidates.iter().enumerate() {
        let Ok(bytes) = std::fs::read(path) else { continue };
        let Ok(value) = serde_json::from_slice::<Value>(&bytes) else { continue };
        // The shared file must name this request; the per-request copy is attributable by its path.
        if index > 0 && value["request_id"].as_str() != Some(id) {
            continue;
        }
        let ok = value["ok"].as_bool().unwrap_or(false);
        let detail = value["detail"].as_str().unwrap_or("(no detail recorded)").to_string();
        return Some((ok, detail, path.clone()));
    }
    None
}

/// The queue's last word about the request: `phase: detail`, or a sentence saying there is none.
fn last_step(id: &str) -> String {
    match queue::read(id) {
        Some(record) => {
            let phase = record["phase"].as_str().unwrap_or("(no phase)");
            let detail = record["detail"].as_str().unwrap_or("");
            let updated = record["updated_at"].as_u64().unwrap_or(0);
            let age = now_epoch().saturating_sub(updated);
            format!("{phase}: {detail} ({age}s before this report)")
        }
        None => "the queue holds no step for it".to_string(),
    }
}

/// The text the session receives. Written once, at settle time, and stored in the notice so a later reader
/// sees exactly what was sent - not what today's code would have written.
fn notice_text(record: &Value, outcome: &str, detail: &str) -> String {
    let id = record["id"].as_str().unwrap_or("");
    let reason = record["reason"].as_str().unwrap_or("(no reason given)");
    let pid = record["installer_pid"].as_u64().map(|pid| pid as u32);
    let install = install_dir();
    let files = format!(
        "{}/installed.txt, {}/deploy-result.json, {}/deploy.out",
        install.display(),
        install.display(),
        sentinel_dir().display()
    );
    // The caller's own words for what to do next, carried verbatim: the session wrote them for itself, and a
    // notice that dropped them would make it re-derive its own intent.
    let continuation = match record["prompt"].as_str().unwrap_or("").trim() {
        "" => String::new(),
        prompt => format!("\nYour own continuation for this deploy: {prompt}"),
    };
    match outcome {
        "success" => format!(
            "Deploy {id} finished: {detail}.\n\
             installed.txt now names {commit}.\n\
             Asked for: {reason}\n\
             Evidence: {files}\n\
             This is the installer's own verdict for this request id; it is not a check of the running node. \
             Verify with scripts/verify-install.sh before saying what the node serves.{continuation}",
            commit = installed_commit(),
        ),
        "failure" => format!(
            "Deploy {id} FAILED: {detail}\n\
             Nothing in this report establishes what is installed. installed.txt names {commit}.\n\
             Asked for: {reason}\n\
             Evidence: {files}{continuation}",
            commit = installed_commit(),
        ),
        // Anything else is the watchdog: no outcome reached the session in time. It says what it knows and
        // claims nothing more - in particular it does not say the deploy failed, because a slow install and a
        // dead one look identical from here.
        _ => {
            let installer = match pid {
                Some(pid) => format!("pid {pid} ({})", if pid_alive(pid) { "still running" } else { "gone" }),
                None => "no pid was recorded (the sentinel that spawned it never got that far)".to_string(),
            };
            format!(
                "Deploy {id} is SILENT: no outcome reached this session within {timeout}s of the installer \
                 starting (WA_SENTINEL_DEPLOY_TIMEOUT).\n\
                 What is known: installer {installer}; last step {step}; installed.txt names {commit}.\n\
                 Asked for: {reason}\n\
                 Evidence: {files}\n\
                 This notice does not establish that the deploy failed or succeeded, and no second notice will \
                 come for it: check installed.txt and deploy-result.json before saying \"deployed\".{continuation}",
                timeout = timeout_secs(),
                step = last_step(id),
                commit = installed_commit(),
            )
        }
    }
}

/// Open the ledger for a deploy that named a session. Called before the request file is written, so a crash
/// between the two leaves a record that the watchdog can still settle - never a deploy with nobody to tell.
///
/// A deploy with no session opens nothing: there is no destination for a notice, and inventing one (a log
/// line, an audit entry) is what "nobody was told" looked like. The request itself stays visible in the queue
/// and in `status`, which is where a caller who passed no `--session` must look.
pub(crate) fn open(id: &str, request: &Value) -> Result<()> {
    let session = request["session"].as_str().unwrap_or("");
    if session.is_empty() {
        return Ok(());
    }
    let Some(path) = record_path(id) else { bail!("deploy outcome id {id:?} cannot name a record") };
    if path.exists() {
        return Ok(());
    }
    let record = json!({
        "schema": 1,
        "id": id,
        "session": session,
        "prompt": request["prompt"].as_str().unwrap_or(""),
        "reason": request["reason"].as_str().unwrap_or("(no reason given)"),
        "requested_at": request["queued_at"].as_u64().unwrap_or_else(now_epoch),
        "installer_pid": Value::Null,
        "started_at": Value::Null,
        "state": "pending",
        "outcome": Value::Null,
        "detail": "",
        "settled_at": Value::Null,
        "notice": Value::Null,
    });
    wa_operation::atomic_json(&path, &record)
        .with_context(|| format!("write the deploy outcome record {}", path.display()))?;
    audit("deploy-outcome-open", id, session);
    Ok(())
}

/// The installer exists: remember which process (when the caller knows one), so a report can say whether it is
/// still alive and so the watchdog's clock starts at the install, not at the idle wait before it.
pub(crate) fn started(id: &str, pid: Option<u32>) {
    let Some(path) = record_path(id) else { return };
    let Some(mut record) = read(id) else { return };
    if record["state"].as_str() != Some("pending") {
        return;
    }
    let known = pid.map(|pid| pid as u64).unwrap_or(0);
    if record["started_at"].as_u64().is_some() && record["installer_pid"].as_u64().unwrap_or(0) == known {
        return;
    }
    if let Some(pid) = pid {
        record["installer_pid"] = json!(pid);
    }
    if record["started_at"].as_u64().is_none() {
        record["started_at"] = json!(now_epoch());
    }
    if let Err(error) = wa_operation::atomic_json(&path, &record) {
        audit("deploy-outcome-start-failed", id, &error.to_string());
    }
}

/// Put the one notice in the box and mark the record settled. Returns whether *this* call was the one that
/// settled it.
///
/// The order matters and is deliberate: the notice is written first, the record second. A crash between the
/// two leaves a pending record whose notice is already in the box; the next attempt writes the same key with
/// the same value, the identity check below accepts it, and the record is marked settled. A crash the other
/// way round would leave a record that says "reported" with no report.
pub(crate) fn settle(id: &str, outcome: &str, detail: &str) -> Result<bool> {
    let Some(path) = record_path(id) else { bail!("deploy outcome id {id:?} cannot name a record") };
    if !path.exists() {
        // No ledger record: this deploy never named a session (or it is a protocol deploy, whose own return
        // engine reports it). Nothing to do, and nothing invented.
        return Ok(false);
    }
    // One settler at a time per deploy: the installer's exit, its result file and the watchdog can all see
    // the same deploy, and "exactly one notice" is decided here.
    let lock = open_lock(&dir().join(format!("{id}.lock")))?;
    lock.lock()?;
    let mut record: Value = serde_json::from_slice(&std::fs::read(&path)?)
        .with_context(|| format!("read the deploy outcome record {}", path.display()))?;
    if record["state"].as_str() == Some("settled") {
        return Ok(false);
    }
    let session = record["session"].as_str().unwrap_or("").to_string();
    if session.is_empty() {
        record["state"] = json!("settled");
        record["outcome"] = json!(outcome);
        record["detail"] = json!(clip(detail, 1000));
        record["settled_at"] = json!(now_epoch());
        wa_operation::atomic_json(&path, &record)?;
        return Ok(true);
    }
    let text = notice_text(&record, outcome, detail);
    let key = format!("deploy-return-{id}.json");
    let wake = json!({
        "verb": "wake",
        "session": session,
        "prompt": text,
        "reason": format!("deploy {outcome}: {}", record["reason"].as_str().unwrap_or("(no reason given)")),
        "deploy_return": id,
    });
    {
        let _queue = queue_lock()?;
        // A deterministic key is what makes this survive a restart *and* stay single: a second settler finds
        // the same file, compares it with what it would have written, and adopts it instead of adding one.
        let mut existing: Option<Value> = None;
        for lane in ["requests", "claimed", "done", "failed"] {
            let path = sentinel_dir().join(lane).join(&key);
            if !path.exists() {
                continue;
            }
            // A notice for this deploy is already in the box. It has been, or will be, delivered - so it is
            // adopted and nothing new is written. If it differs from what this settler would have said (an
            // installer that reported after the watchdog had already spoken), the box wins: the record must
            // name the notice the session actually receives.
            let stored = match std::fs::read(&path).ok().and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok()) {
                Some(stored) if lane == "done" || lane == "failed" => stored["request"].clone(),
                Some(stored) => stored,
                None => bail!("deploy notice {key} exists but is unreadable; not adding a second one"),
            };
            existing = Some(stored);
            break;
        }
        let sent = match existing {
            Some(stored) => stored,
            None => {
                let path = sentinel_dir().join("requests").join(&key);
                wa_operation::atomic_json(&path, &wake)
                    .with_context(|| format!("queue the deploy notice {}", path.display()))?;
                wake
            }
        };
        record["notice"] = sent;
    }
    record["state"] = json!("settled");
    record["outcome"] = json!(outcome);
    record["detail"] = json!(clip(detail, 1000));
    record["settled_at"] = json!(now_epoch());
    wa_operation::atomic_json(&path, &record)?;
    audit("deploy-outcome", id, &format!("{outcome}: {}", clip(detail, 200)));
    Ok(true)
}

/// The installer the sentinel spawned has exited. Its result file is the better evidence when it wrote one:
/// `deploy.sh` can exit non-zero after recording a complete install, and it can be killed after recording a
/// refusal. Only when it recorded nothing does the exit status decide.
pub(crate) fn settle_from_exit(id: &str, success: bool) {
    let outcome = match installer_result(id) {
        Some((ok, detail, path)) => (
            if ok { "success" } else { "failure" }.to_string(),
            format!("{detail} [{}]", path.display()),
        ),
        None if success => ("success".to_string(), "the installer exited successfully and recorded no result file".to_string()),
        None => (
            "failure".to_string(),
            "the installer exited with an error status and recorded no result file; its output is in sentinel/deploy.out".to_string(),
        ),
    };
    if let Err(error) = settle(id, &outcome.0, &outcome.1) {
        audit("deploy-outcome-failed", id, &error.to_string());
    }
}

/// Which dispatch state a request is in, read from the box itself.
fn still_in_the_box(id: &str) -> bool {
    let key = format!("{id}.json");
    ["requests", "claimed"].iter().any(|lane| sentinel_dir().join(lane).join(&key).exists())
}

/// The watchdog. Called by the watcher every few seconds and once at watcher start.
///
/// Two ways a deploy is due a report:
///
///   * its installer started and the session has heard nothing for [`timeout_secs`] - whether the installer
///     is still running or not. A slow install and a dead one look the same from the session's side, and the
///     notice says which it is; waiting for the process to die is how a session came to sit idle for hours;
///   * it never started (`started_at` is absent) and the request is no longer in the box: it was claimed and
///     its worker died, or it was refused. Then the clock runs from the request.
///
/// A request that is *still* in the box is not silent: the sentinel is holding it (a deploy waits for an idle
/// node), it says so in `status`, and the measured 06:39/07:09 deploys were held exactly like that while
/// their own turn was in flight. Waking a session to say "held, as the queue already says" would be the
/// watchdog inventing a problem.
pub(crate) fn sweep(now: u64) -> u32 {
    let Ok(entries) = std::fs::read_dir(dir()) else { return 0 };
    let timeout = timeout_secs();
    let mut reports = 0;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        let Ok(bytes) = std::fs::read(&path) else { continue };
        let Ok(record) = serde_json::from_slice::<Value>(&bytes) else {
            audit("deploy-outcome-unreadable", &path.display().to_string(), "not settled by the watchdog");
            continue;
        };
        if record["state"].as_str() != Some("pending") {
            // Settled records are evidence for a week, like a failed queue record, and then they are history: the
            // door is a directory that lives on the machine, and one small file per deploy adds up over a year.
            if record["settled_at"].as_u64().is_some_and(|at| now.saturating_sub(at) > 7 * 86_400) {
                let _ = std::fs::remove_file(&path);
            }
            continue;
        }
        let id = record["id"].as_str().unwrap_or("");
        // The installer wrote its verdict before it died: that *is* the outcome, and it is better than a
        // timeout. This is the case that survives the sentinel being replaced mid-deploy.
        if let Some((ok, detail, path)) = installer_result(id) {
            let outcome = if ok { "success" } else { "failure" };
            match settle(id, outcome, &format!("{detail} [{}]", path.display())) {
                Ok(true) => reports += 1,
                Ok(false) => {}
                Err(error) => audit("deploy-outcome-failed", id, &error.to_string()),
            }
            continue;
        }
        let started = record["started_at"].as_u64();
        // A deploy in a named installer state is not silence. `waiting_for_idle` says nothing has been
        // stopped and the sessions have been asked to pause; its own bound is how long that may last.
        let phase = installer_phase();
        let waiting = phase.as_ref().is_some_and(|(state, _)| state == "waiting_for_idle");
        let waiting_bound = phase.as_ref().and_then(|(_, bound)| *bound).unwrap_or(0);
        let grace = if waiting { waiting_bound } else { 0 };
        let due = match started {
            Some(started) => started.saturating_add(timeout).saturating_add(grace),
            None if still_in_the_box(id) => continue,
            None => record["requested_at"].as_u64().unwrap_or(now).saturating_add(timeout),
        };
        if now < due {
            continue;
        }
        let (outcome, detail) = if waiting {
            ("waiting_for_idle", "the deploy was waiting for the node to become idle when its own bound                 (WA_DEPLOY_IDLE_BOUND) ran out; nothing was stopped and no outcome reached the session")
        } else {
            ("silent", "the watchdog reported it; no outcome reached the session in time")
        };
        match settle(id, outcome, detail) {
            Ok(true) => reports += 1,
            Ok(false) => {}
            Err(error) => audit("deploy-outcome-failed", id, &error.to_string()),
        }
    }
    reports
}
