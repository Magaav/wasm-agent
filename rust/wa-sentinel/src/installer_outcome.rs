//! A SPAWNED INSTALLER ALWAYS ENDS IN A VERDICT: installed, or failed with its own reason.
//!
//! MEASURED (23/11, this laptop): the deploy of `ffd2a0a5` was spawned at `1795475320` (22:28:40Z), the installer
//! refused it (`deploy: refused(component_proof_failed): the candidate binary did not answer a graph call through
//! the staged component; nothing installed`, `sentinel/deploy.out`), and it wrote none of the protocol files the
//! return engine needs - so `sentinel.log` says
//!
//!   1795475660  return-observation-problem    … cannot be observed: missing binding.json, ack.json, intent.json
//!   1795475960  return-observation-retired      … unchanged for 300s, so the directory was retired
//!
//! and then nothing: `installed.txt` still named `4425f670`, the box said `0 waiting`, and the same request had to
//! be made again by hand forty minutes later. A request is admitted to install; once an installer has been spawned
//! for it, "nothing happened" is not one of the outcomes it may have.
//!
//! This module is the file-only answer to "what became of that installer": the request's own queue record (which
//! names the commit it asked for and the reason it was asked), the install record beside the binary, and the
//! installer's own block in `deploy.out`. It performs nothing; the caller (`observation.rs`, the lane that decides
//! whether a protocol directory can still be observed) uses it in place of retiring a directory whose deploy
//! already ended.

use super::*;

/// What became of one spawned installer, from files only.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// The install record names the commit this request asked for.
    Installed,
    /// The installer wrote its own terminal line, and it was not a success: the sentence is that line.
    Uninstalled(String),
    /// No terminal line yet: it may be building, waiting for idle, or installing. Nothing may be claimed.
    Running,
}

/// The lines a run of `scripts/deploy.sh` ends with (its own words, not this module's).
fn is_terminal(line: &str) -> bool {
    let line = line.trim_start();
    line.starts_with("deploy: refused(")
        || line.starts_with("deploy: failed")
        || line.starts_with("deploy: installed")
        || line.starts_with("deploy: rolled back")
        || line.starts_with("deploy: nothing installed")
}

/// The installer's block for one request: from the last `--- deploy unit … reason <reason>` line to the end of the
/// log, and its terminal line if it has one.
///
/// The spelling the spawn writes is `--- deploy unit <unit> at <epoch> script <path> reason <reason>`
/// (`main.rs`, the deploy spawn), and the reason is the request's own - which is what makes this block findable
/// without a request id the installer never received.
fn block<'a>(log: &'a str, reason: &str) -> Option<(Vec<&'a str>, Option<String>)> {
    let needle = format!("reason {reason}");
    let mut start = None;
    for (index, line) in log.lines().enumerate() {
        if line.starts_with("--- deploy unit") && line.contains(&needle) {
            start = Some(index);
        }
    }
    let start = start?;
    let lines: Vec<&str> = log.lines().skip(start).collect();
    let terminal = lines.iter().rev().find(|line| is_terminal(line)).map(|line| line.trim().to_string());
    Some((lines, terminal))
}

/// The verdict for one request, from three facts - the commit it asked for, the commit the install record names,
/// and the installer's log. Pure, so the decision is judged without a filesystem (installer_outcome_tests.rs).
pub(crate) fn verdict_of(target: &str, installed: &str, log: &str, reason: &str) -> Outcome {
    let target = target.trim();
    if target.is_empty() {
        return Outcome::Running; // no request, no verdict: unknown is not yes
    }
    // Installed first: the record is the fact an install leaves, and it is named by commit.
    if !installed.trim().is_empty() && target.starts_with(installed.trim()) {
        return Outcome::Installed;
    }
    match block(log, reason) {
        // A TERMINAL LINE IS THE INSTALLER'S OWN VERDICT, and it outranks a build that has not reached the record
        // yet: `deploy: installed` is a success the record will name a moment later, and anything else is a
        // refusal whose sentence belongs in the request's failure.
        Some((_, Some(line))) if line.starts_with("deploy: installed") => Outcome::Installed,
        Some((_, Some(line))) => Outcome::Uninstalled(line),
        // No block: this log is not this request's (an older watcher, a rotated log). The install record still
        // answers "is it installed", and a target that is not the record's is not installed - said plainly, with
        // no claim about why.
        None => Outcome::Uninstalled(format!(
            "no installer block for this request in {}: the install record names {}",
            log_path().display(),
            if installed.trim().is_empty() { "no commit" } else { installed.trim() }
        )),
        Some((_, None)) => Outcome::Running,
    }
}

/// The verdict for `id`, read from the files a sentinel has: its own queue record for the request, the install
/// record beside the installed binary, and the installer's log.
pub(crate) fn verdict(id: &str) -> Option<Outcome> {
    let record = std::fs::read(sentinel_dir().join("done").join(format!("{id}.json")))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())?;
    let request = record.get("request").cloned().unwrap_or(Value::Null);
    let target = request.get("target_commit").and_then(Value::as_str)
        .or_else(|| request.get("expected_sha").and_then(Value::as_str))
        .unwrap_or("")
        .to_string();
    let reason = request.get("reason").and_then(Value::as_str).unwrap_or("");
    let installed = deploy_outcome::installed_commit();
    let log = std::fs::read_to_string(log_path()).unwrap_or_default();
    Some(verdict_of(&target, &installed, &log, reason))
}

/// THE REQUEST A SPAWNED INSTALLER NEVER FINISHED ENDS HERE: `failed/` with the installer's own reason, one queue
/// record, and one re-queue for the next quiet moment - never a retirement and never a silence.
///
/// Idempotent: a request that already has a `failed/` record is not touched again (the re-queue sidecar is the
/// same `schedule_requeue` the bound uses, which is itself once-per-request).
pub(crate) fn fail_unobserved(id: &str, why: &str) -> Result<bool> {
    let done_path = sentinel_dir().join("done").join(format!("{id}.json"));
    let failed_path = sentinel_dir().join("failed").join(format!("{id}.json"));
    if failed_path.exists() {
        return Ok(false);
    }
    let record: Value = match std::fs::read(&done_path).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok()) {
        Some(record) => record,
        None => return Ok(false),
    };
    let request = record.get("request").cloned().unwrap_or(Value::Null);
    if !request.is_object() {
        return Ok(false);
    }
    let retry = format!("re-request with: wa-sentinel request deploy --expected-sha {} --reason '{}'",
        request.get("target_commit").and_then(Value::as_str).unwrap_or(""),
        request.get("reason").and_then(Value::as_str).unwrap_or("").replace('\'', ""));
    let detail = format!("the installer ended and nothing was installed: {why}; it is re-queued automatically once, when this node is next quiet; {retry}");
    wa_operation::atomic_json(&failed_path, &json!({
        "request": request, "ok": false, "phase": "unobserved", "detail": detail, "at": now_epoch()
    }))?;
    queue::observe(&request, id, "failed", "unobserved", &detail);
    if request.get("requeued").and_then(Value::as_bool) != Some(true) {
        schedule_requeue(&request, &format!("{id}.json"), &detail)?;
    }
    // ONE NOTICE, when the request named a session: the deploy-outcome record is the exactly-once path to it.
    if request.get("session").and_then(Value::as_str).map(|value| !value.is_empty()).unwrap_or(false) {
        let _ = deploy_outcome::open(id, &request);
        let _ = deploy_outcome::settle(id, "failed", &detail);
    }
    audit("deploy-unobserved-failed", id, &detail);
    say(&format!("deploy {id} failed without a verdict: {detail}"));
    Ok(true)
}
