//! The `spell` verb: run a *declared plan* exported by the node, while the node cannot run it.
//!
//! Why this exists. A spell is a plan the node executes through its Lua worker, and the worker is
//! one thread that a turn occupies. So the spells that most need to run - the ones that restart or
//! replace the node - cannot run there: the executor dies with the thing it is changing, and its own
//! `post` assertions then never run. This verb closes that gap by executing the plan **outside** the
//! node, in the one process that outlives it.
//!
//! Why JSON and not WASM. The plugin ABI in `wa-host` is a *core module with no imports*: a guest
//! gets `memory`, `alloc`, `describe`, `call` and nothing else - no filesystem, no clock, no way to
//! ask for anything. Such a module can compute a plan and hand it back; it cannot execute one step
//! of it. Packaging spells as modules would therefore *remove* capability, not add it. A plan file
//! is the right shape for a sequence, and a JSON plan needs no toolchain on the upgrade path.
//!
//! Why a whitelist rather than a script. `SENTINEL.md` states the boundary: "a verb list, never a
//! shell. The thing that can restart your agent must not be something your agent can talk into
//! anything." A spell file is written by the agent, so it is *untrusted input to this process*. It
//! therefore names steps from a fixed set, and the sentinel refuses anything else - including
//! `run`, which is the escape hatch this verb must never become.

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// What a spell file may ask for. Deliberately tiny, and deliberately *not* extensible by the file.
///
/// Every entry is an action this process already performs under its own rules, with its own
/// preconditions (`upgrade` proves the binary, `wait-idle` refuses a busy node). The spell chooses
/// *which* and in what order; it cannot choose *how*. `run` is absent on purpose - a spell that
/// could reach it would be a shell, and then the verb list would be decoration.
const ALLOWED_STEPS: &[&str] = &["wait-idle", "upgrade", "restart", "wait-health"];

/// How long a single step may take before it is a failure rather than a wait. `upgrade` waits for
/// idle internally and can legitimately take minutes; the rest are bounded.
const STEP_TIMEOUT_SECS: u64 = 900;

struct Step {
    kind: String,
    binary: String,
}

/// Read and validate a plan. Validation is total: an unreadable file, an unknown step, a step with
/// a missing argument, or an empty plan are all errors *before* anything runs. A half-executed plan
/// is worse than a refused one - the same rule `upgrade.sh` applies to a half-restored edit.
fn read_plan(path: &Path) -> Result<Vec<Step>> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("read the spell file {}", path.display()))?;
    let plan: Value = serde_json::from_str(&text)
        .with_context(|| format!("{} is not valid JSON", path.display()))?;

    let name = plan.get("name").and_then(Value::as_str).unwrap_or("(unnamed)");
    // A plan must settle its effect, exactly as a spell does. Without at least one postcondition
    // there is no way for this process to know the plan did anything, and "reported success while
    // doing nothing" is the v8 failure mode spells were built to end.
    let post = plan.get("post").and_then(Value::as_array).cloned().unwrap_or_default();
    if post.is_empty() {
        bail!("spell {name:?} declares no post conditions, so its effect cannot be settled - refusing to run it");
    }

    let raw = plan
        .get("steps")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if raw.is_empty() {
        bail!("spell {name:?} has no steps");
    }

    let mut steps = Vec::new();
    for (index, value) in raw.iter().enumerate() {
        let number = index + 1;
        let kind = value.get("kind").and_then(Value::as_str).unwrap_or("").to_string();
        if kind != "sentinel" {
            // A spell exported for the sentinel may only contain steps the sentinel can perform.
            // Anything else (a client action, a CDP assert) belongs to the node and would silently
            // do nothing here - so it is refused rather than skipped.
            bail!(
                "step {number} has kind {kind:?}; a sentinel plan may only contain `sentinel` steps"
            );
        }
        let verb = value.get("verb").and_then(Value::as_str).unwrap_or("");
        if !ALLOWED_STEPS.contains(&verb) {
            bail!(
                "step {number} asks for {:?}, which is not one of {} - a spell chooses which step, never how it runs",
                verb,
                ALLOWED_STEPS.join(" | ")
            );
        }
        let binary = value.get("binary").and_then(Value::as_str).unwrap_or("").to_string();
        // `binary` is required only where it means something. Every other verb is refused a binary
        // rather than ignoring one, so a plan cannot carry a value that is quietly dropped.
        match verb {
            "upgrade" => {
                if binary.is_empty() {
                    bail!("step {number} is `upgrade` but names no `binary`");
                }
                if !Path::new(&binary).exists() {
                    // Checked before any step runs: an upgrade to a path that does not exist would
                    // otherwise stop the node and then fail to start it.
                    bail!("step {number} names {binary}, which does not exist");
                }
            }
            _ => {
                if !binary.is_empty() {
                    bail!("step {number} is {verb:?}, which takes no `binary` - remove it rather than have it ignored");
                }
            }
        }
        steps.push(Step { kind: verb.to_string(), binary });
    }
    Ok(steps)
}

/// Run a plan: the steps in order, then the postconditions, then the verdict.
///
/// First failure stops the run with the failing index - the same contract `spells.lua` implements,
/// so a plan behaves the same whether the node or this process executes it.
pub fn verb_spell(path: &str, reason: &str) -> Result<String> {
    if path.is_empty() {
        bail!("spell needs --file");
    }
    let path = PathBuf::from(path);
    if !path.exists() {
        bail!("no spell file at {}", path.display());
    }
    let steps = read_plan(&path)?;
    let name = std::fs::read_to_string(&path)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v.get("name").and_then(Value::as_str).map(|s| s.to_string()))
        .unwrap_or_else(|| "(unnamed)".into());

    let mut trace: Vec<Value> = Vec::new();
    let started = std::time::Instant::now();
    for (index, step) in steps.iter().enumerate() {
        let number = index + 1;
        let at = std::time::Instant::now();
        let outcome = match step.kind.as_str() {
            "wait-idle" => wait_idle(),
            "wait-health" => wait_health(),
            "restart" => crate::verb_restart(&format!("{reason} (spell {name})")),
            "upgrade" => crate::verb_upgrade(&step.binary, &format!("{reason} (spell {name})")),
            other => bail!("step {number} has kind {other:?}, which passed validation but is not implemented - this is a bug"),
        };
        let ok = outcome.is_ok();
        trace.push(json!({
            "index": number,
            "kind": step.kind,
            "ok": ok,
            "ms": at.elapsed().as_millis() as u64,
            "detail": match &outcome { Ok(d) => json!(d), Err(e) => json!(e.to_string()) },
        }));
        if let Err(error) = outcome {
            crate::audit("spell-failed", &format!("{name} step {number}"), reason);
            return Ok(json!({
                "ok": false, "spell": name, "step": number,
                "error": "step_failed", "detail": error.to_string(),
                "ms": started.elapsed().as_millis() as u64, "trace": trace,
            })
            .to_string());
        }
        if at.elapsed().as_secs() > STEP_TIMEOUT_SECS {
            bail!("step {number} took longer than {STEP_TIMEOUT_SECS}s");
        }
    }

    // Effect settlement, observed by the process that survived the plan. For an upgrade this is the
    // assertion the node could never make about itself: it is the *outside* that can see the new
    // binary answering.
    match wait_health() {
        Ok(_) => {
            crate::audit("spell", &name, reason);
            Ok(json!({
                "ok": true, "spell": name, "settled": true,
                "steps": steps.len(),
                "ms": started.elapsed().as_millis() as u64,
                "trace": trace,
            })
            .to_string())
        }
        Err(error) => {
            crate::audit("spell-failed", &format!("{name} post"), reason);
            Ok(json!({
                "ok": false, "spell": name, "error": "postcondition_failed",
                "detail": format!("the node did not answer /health after the plan: {error}"),
                "ms": started.elapsed().as_millis() as u64, "trace": trace,
            })
            .to_string())
        }
    }
}

/// Wait for the node to have no turn running. A plan that restarts a node must not do it mid-turn;
/// this is the reason `upgrade.sh` has the same loop, and reusing the *rule* here (rather than
/// reimplementing the check) is what stops the two from disagreeing.
fn wait_idle() -> Result<String> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(STEP_TIMEOUT_SECS);
    loop {
        if crate::node_is_idle() {
            return Ok("idle".into());
        }
        if std::time::Instant::now() > deadline {
            bail!("the node was still busy after {STEP_TIMEOUT_SECS}s");
        }
        std::thread::sleep(std::time::Duration::from_secs(5));
    }
}

fn wait_health() -> Result<String> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    loop {
        if let Some(value) = crate::health() {
            if value.get("ok").and_then(Value::as_bool) == Some(true) {
                return Ok("healthy".into());
            }
        }
        if std::time::Instant::now() > deadline {
            bail!("no healthy answer from the node");
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
}
