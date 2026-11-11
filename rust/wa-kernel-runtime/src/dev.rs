//! The dev-loop hook: swap one running service instance for another, in place (`wa dev`).
//!
//! A build that lands while a component is running has two jobs: prove the new bytes actually run
//! (`lifecycle.report(ready)`), and give up nothing if they do not. So the new instance starts
//! **beside** the old one on the same name, grant and state, is waited on for a health report, and
//! only then stops the old instance. If the new one never reports, or exits first, the old instance
//! is left running and nothing is swapped (docs/SERVICE-COMPONENTS.md, "Iterating on a component").
//!
//! What this module is not: a registry. The supervisor in `services.rs` owns the node's named
//! instances; a dev instance lives in the caller's `Option<DevInstance>` and never enters that
//! registry, so `wa dev` cannot disturb a node's running services, and a `wa serve` cannot stop a
//! dev instance by name. The instance itself is `services::spawn_instance` - the same compile,
//! grant, migration, log and supervision a real start uses - so what a dev loop proves is what a
//! start does.
//!
//! Two kinds of instance coexist by construction: the old one is already running its own thread and
//! its own store, and the new one is a second thread with a second store. Nothing is shared between
//! them except the component's kv file and its log file (both opened per instance), which is what
//! makes the swap observable: after `swap` returns, the log's tail is the new instance's, and the
//! old instance wrote "stopping cleanly" before the new one's first line.

use crate::components::{load, Grant, Installed};
use crate::services::{spawn_instance, Shared};
use serde_json::{json, Value};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// How often the readiness loop looks at an instance's health.
const POLL: Duration = Duration::from_millis(20);

/// One supervised instance owned by a caller rather than by the node's registry.
pub struct DevInstance {
    name: String,
    sha256: String,
    shared: Arc<Shared>,
    thread: Option<std::thread::JoinHandle<()>>,
    /// The instance's identity, so stopping it revokes *its* registrations and not the name's: a hot
    /// swap has two instances of the same name alive at once (`registrations`).
    instance: crate::registrations::Instance,
}

impl DevInstance {
    pub fn name(&self) -> &str {
        &self.name
    }
    pub fn sha256(&self) -> &str {
        &self.sha256
    }
    /// The last `lifecycle.report`, as `"ready"`, `"ready: detail"`, `"degraded"`, `"starting"` or
    /// `""` when the component never reported.
    pub fn health(&self) -> String {
        self.shared.health.lock().unwrap().clone()
    }
    /// `starting`, `running`, `backoff`, `stopped`.
    pub fn state(&self) -> String {
        self.shared.state.lock().unwrap().clone()
    }
    /// The outcome of the run that ended (`exit_0`, `exit_3`, `trap:…`), `""` while it has not.
    pub fn last_exit(&self) -> String {
        self.shared.last_exit.lock().unwrap().clone()
    }
    pub fn is_alive(&self) -> bool {
        self.thread.as_ref().is_some_and(|thread| !thread.is_finished())
    }

    /// Ask this instance to stop and wait for it, with the supervisor's grace: a component that
    /// checks `lifecycle.stopping()` returns cleanly, one that does not is trapped after it.
    pub fn stop(&mut self) -> String {
        self.shared.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        // A dev instance is not in the node's registry, so nothing else would revoke it: without this,
        // a swap left the stopped instance's bus token attached and its ledger rows behind, and the
        // next plan saw a provider that was not running and a subscriber nobody could see.
        crate::registrations::node().revoke_generation(&self.name, self.instance.generation);
        self.last_exit()
    }

    /// The instance token (`name#generation`) this slot holds.
    pub fn instance(&self) -> &crate::registrations::Instance {
        &self.instance
    }

    /// Wait until the instance reports health, exits, or the deadline passes.
    ///
    /// `Ready` is a report of `ready` or `degraded`: a degrading component still answers, so it is
    /// allowed to take over (the same rule the supervisor applies to traffic).
    pub fn wait_ready(&self, within: Duration) -> Result<String, Wait> {
        wait_ready(&self.shared, self.thread.as_ref(), within)
    }
}

/// The health rule, in one place for both callers of a started instance: the dev loop
/// (`DevInstance::wait_ready`) and the transactional upgrade (`install::upgrade`).
///
/// `ready`/`degraded` is health; a thread that is gone is an exit; and an instance that runs for the
/// whole window without reporting is [`Wait::Unreported`] - `lifecycle.report` is optional in the WIT
/// and absent in a wasip1 module, so "alive after the wait" is the strongest thing that can be said
/// and both callers accept it *out loud* rather than inventing health.
pub(crate) fn wait_ready(
    shared: &Arc<Shared>,
    thread: Option<&std::thread::JoinHandle<()>>,
    within: Duration,
) -> Result<String, Wait> {
    let deadline = Instant::now() + within;
    loop {
        if thread.is_some_and(|thread| thread.is_finished()) {
            return Err(Wait::Exited(shared.last_exit.lock().unwrap().clone()));
        }
        let health = shared.health.lock().unwrap().clone();
        if health.starts_with("ready") || health.starts_with("degraded") {
            return Ok(health);
        }
        if Instant::now() >= deadline {
            return Err(Wait::Unreported(health));
        }
        std::thread::sleep(POLL);
    }
}

/// Why `wait_ready` gave up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Wait {
    /// The instance returned or trapped before reporting: the outcome string.
    Exited(String),
    /// Still running, but no health report in the whole window: its last report, maybe empty.
    Unreported(String),
}

use Wait as W;

/// Start one instance from a `services`-shaped request (`{name, env, file_env, net, config}`): the
/// component must already be installed in the component directory this process resolves, which is
/// how `wa dev` lays down the build it just made.
pub fn start(request: &Value) -> Result<DevInstance, String> {
    let name = request.get("name").and_then(Value::as_str).unwrap_or_default();
    let installed: Installed = load(name).map_err(|error| error.to_string())?;
    if installed.manifest.get("kind").and_then(Value::as_str) != Some("service") {
        return Err("component_is_not_a_service".into());
    }
    let grant = Grant::from_request(request)
        .and_then(|grant| grant.check(&installed.manifest).map(|_| grant))
        .map_err(|error| error.to_string())?;
    start_installed(installed, grant)
}

fn start_installed(installed: Installed, grant: Grant) -> Result<DevInstance, String> {
    let spawned = spawn_instance(installed, grant).map_err(|error| error["error"].as_str().unwrap_or("spawn_refused").to_string())?;
    Ok(DevInstance {
        name: spawned.name.clone(),
        sha256: spawned.sha256,
        shared: spawned.shared,
        thread: spawned.thread,
        instance: spawned.instance,
    })
}

/// Start, wait for health, stop the old one. See the module docs for why the old instance is never
/// stopped before the new one is known good.
///
/// `force_restart` asks for the other order (stop, then start) - the shape a component needs when
/// two instances cannot coexist (a fixed port, a device, a lock): the caller says so, because the
/// host cannot know, and the answer says which order was used.
///
/// Since 11/11 a name may hold only one instance at a time (`services::claim`), so the hot path is
/// only reachable when *nothing* of this name is live - a first build of a loop, or a slot whose
/// instance the host has already retired. A name that is claimed is restarted in the other order,
/// and the answer says why (`because: one instance per name`).
pub fn swap(slot: &mut Option<DevInstance>, request: &Value, ready: Duration, force_restart: bool) -> Value {
    let name = request.get("name").and_then(Value::as_str).unwrap_or_default().to_string();
    let began = Instant::now();
    let previous = slot.as_ref().map(|old| json!({"sha256": old.sha256(), "health": old.health()}));
    let claimed = crate::services::claimed(&name);
    if force_restart || slot.is_none() || claimed {
        // The other order, for a component whose two instances cannot coexist: stop, then start. The
        // answer names the order that was used, so `--restart` reads the same with or without an
        // instance to stop (there is nothing to swap in on the first build of a loop).
        let mode = if force_restart { "restart" } else if claimed && slot.is_none() { "kept_previous" } else { "start" };
        let stop_began = Instant::now();
        let previous_exit = slot.take().map(|mut old| old.stop());
        let stop_ms = stop_began.elapsed().as_millis() as u64;
        let started = Instant::now();
        let mut instance = match start(request) {
            Ok(instance) => instance,
            Err(error) => return json!({"ok": false, "name": name, "mode": mode, "error": error, "previous": previous}),
        };
        let start_ms = started.elapsed().as_millis() as u64;
        let health = match instance.wait_ready(ready) {
            Ok(health) => health,
            Err(W::Exited(exit)) => {
                let stop = instance.stop();
                return json!({"ok": false, "name": name, "mode": mode, "error": format!("instance_exited:{exit}"), "last_exit": stop, "previous": previous});
            }
            Err(W::Unreported(health)) => format!("unreported:{health}"),
        };
        let sha256 = instance.sha256().to_string();
        *slot = Some(instance);
        return json!({
            "ok": true,
            "name": name,
            "mode": mode,
            "sha256": sha256,
            "health": health,
            "previous": previous,
            "previous_last_exit": previous_exit,
            "start_ms": start_ms,
            "stop_ms": stop_ms,
            "ready_ms": 0,
            "total_ms": began.elapsed().as_millis() as u64,
        });
    }
    // The hot path: the new instance starts beside the old one.
    let started = Instant::now();
    let mut candidate = match start(request) {
        Ok(candidate) => candidate,
        Err(error) => {
            // Nothing started, so nothing can be judged: the old instance keeps running and the
            // refusal is the answer (a broken build must not cost a working instance).
            return json!({"ok": false, "name": name, "mode": "kept_previous", "error": error, "previous": previous, "total_ms": began.elapsed().as_millis() as u64});
        }
    };
    let start_ms = started.elapsed().as_millis() as u64;
    let ready_began = Instant::now();
    let health = match candidate.wait_ready(ready) {
        Ok(health) => health,
        Err(W::Exited(exit)) => {
            let last_exit = candidate.stop();
            return json!({
                "ok": false, "name": name, "mode": "kept_previous",
                "error": format!("candidate_exited:{exit}"), "last_exit": last_exit,
                "previous": previous, "start_ms": start_ms, "total_ms": began.elapsed().as_millis() as u64,
            });
        }
        Err(W::Unreported(health)) => format!("unreported:{health}"),
    };
    let ready_ms = ready_began.elapsed().as_millis() as u64;
    let stop_began = Instant::now();
    let previous_exit = slot.take().map(|mut old| old.stop());
    let stop_ms = stop_began.elapsed().as_millis() as u64;
    let sha256 = candidate.sha256().to_string();
    *slot = Some(candidate);
    json!({
        "ok": true,
        "name": name,
        "mode": "hot_swap",
        "sha256": sha256,
        "health": health,
        "previous": previous,
        "previous_last_exit": previous_exit,
        "start_ms": start_ms,
        "ready_ms": ready_ms,
        "stop_ms": stop_ms,
        "total_ms": began.elapsed().as_millis() as u64,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The slot is the whole contract: after a swap the slot names the new pin, and a start with no
    /// old instance reports `start` rather than a swap. No component is needed for either.
    #[test]
    fn a_start_into_an_empty_slot_is_a_start() {
        // A name that cannot be installed: the answer must be a refusal, not a panic, and the slot
        // must stay empty - the same rule the real call sites depend on.
        let mut slot: Option<DevInstance> = None;
        let answer = swap(&mut slot, &json!({"name": "no-such-component"}), Duration::from_millis(50), false);
        assert_eq!(answer["ok"], false);
        assert_eq!(answer["mode"], "start", "{answer}");
        assert!(slot.is_none());
        assert!(answer["error"].as_str().unwrap_or_default().contains("component_not_installed"), "{answer}");
    }

    /// `--restart` reports the order it used even when there was nothing to stop.
    #[test]
    fn forcing_a_restart_reports_the_restart_order() {
        let mut slot: Option<DevInstance> = None;
        let answer = swap(&mut slot, &json!({"name": "no-such-component"}), Duration::from_millis(50), true);
        assert_eq!(answer["mode"], "restart", "{answer}");
        assert_eq!(answer["ok"], false);
    }
}
