//! Start by imports: the supervisor starts a component when every interface it imports is served
//! (`docs/KERNEL.md`, lesson 3).
//!
//! Configuration order means nothing. A definition that imports `wa:vision/text-reader@0.1.0` cannot
//! start because it happens to be written after its provider in a file, and it does not fail because
//! it is written before it either: it waits, `status` says `waiting for wa:vision/text-reader@0.1.0`,
//! and it starts in the same pass in which the provider's `lifecycle.report(ready)` made that
//! interface served.
//!
//! Three pieces:
//!
//! * [`plan`] is the pure decision: given the definitions, what each artifact imports and what is
//!   already running, it returns the order to start and what each remaining definition waits for. It
//!   simulates the starts, so a provider listed *after* its consumer is planned first - which is the
//!   whole point, and is what the test asserts.
//! * [`reconcile`] performs it for real: `services::start` for everything the plan says, then again
//!   until nothing more can start, and it records what is left in [`pending`] so `services status` can
//!   answer "why is this not running" with an interface name instead of `not_running`.
//! * [`note_started`] / [`note_stopped`] keep the served set current, and [`kick`] re-plans when
//!   something changes (a provider came up, a component stopped). A waiting definition therefore
//!   starts without anybody retrying by hand.
//!
//! What a provider offers is read from the **artifact** (`imports::Interfaces::provides`), never from a
//! manifest field: an operator cannot promote a component to provider by editing JSON, and a component
//! that exports nothing offers nothing.

use crate::imports::Interfaces;
use crate::services;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

/// What is served, by whom: the running components and the interfaces their artifacts export.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Served {
    pub running: BTreeSet<String>,
    pub providers: BTreeMap<String, BTreeSet<String>>,
}

impl Served {
    /// Everything a consumer could import right now.
    pub fn interfaces(&self) -> BTreeSet<String> {
        self.providers.values().flatten().cloned().collect()
    }

    fn add(&mut self, name: &str, provides: &BTreeSet<String>) {
        self.running.insert(name.to_string());
        if !provides.is_empty() {
            self.providers.insert(name.to_string(), provides.clone());
        }
    }
}

/// One definition that cannot start yet, and why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Waiting {
    pub waiting_for: Vec<String>,
    /// `imports_not_served` or `not_installed`: two very different operator problems, so the answer
    /// names them apart.
    pub reason: &'static str,
}

/// The decision for one reconcile pass.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Plan {
    /// The names to start, in the order they can start (providers before consumers).
    pub start: Vec<String>,
    /// Everything else, with the interface it waits for.
    pub waiting: BTreeMap<String, Waiting>,
}

/// `plan` from what is installed: the same decision the node makes, without starting anything.
///
/// `definitions` are the names a caller wants running (a `services` registry's enabled set, a
/// configuration file, a test); definitions already running are left alone.
pub fn plan(definitions: &[String], served: &Served) -> Plan {
    plan_with(definitions, served, &|name: &str| install_lookup(name))
}

/// `plan` with the artifact lookup a caller supplies (a test's fake components).
pub fn plan_with(definitions: &[String], served: &Served, look: &dyn Fn(&str) -> Option<Interfaces>) -> Plan {
    let mut served = served.clone();
    let mut queue: Vec<String> = definitions.iter().filter(|name| !served.running.contains(*name)).cloned().collect();
    let mut plan = Plan::default();
    loop {
        let before = plan.start.len();
        let mut next = Vec::new();
        for name in queue.drain(..) {
            let Some(interfaces) = look(&name) else {
                plan.waiting.insert(name, Waiting { waiting_for: Vec::new(), reason: "not_installed" });
                continue;
            };
            let missing = interfaces.waiting_for(&served.interfaces());
            if missing.is_empty() {
                served.add(&name, &interfaces.provides());
                plan.waiting.remove(&name);
                plan.start.push(name);
            } else {
                plan.waiting.insert(name.clone(), Waiting { waiting_for: missing, reason: "imports_not_served" });
                next.push(name);
            }
        }
        if next.is_empty() || plan.start.len() == before {
            break;
        }
        queue = next;
    }
    plan
}

/// The installed artifact's interfaces, or `None` when this node does not have it.
fn install_lookup(name: &str) -> Option<Interfaces> {
    let installed = crate::components::load(name).ok()?;
    use crate::imports;
    imports::of_installed(&installed).ok()
}

// ---- the node's supervisor state -------------------------------------------------------------

/// Interfaces the running instances serve, keyed by component name.
fn providers() -> &'static Mutex<BTreeMap<String, BTreeSet<String>>> {
    static PROVIDERS: OnceLock<Mutex<BTreeMap<String, BTreeSet<String>>>> = OnceLock::new();
    PROVIDERS.get_or_init(|| Mutex::new(BTreeMap::new()))
}

/// The definitions this node wants running, and the ones that are waiting. Both are rewritten by
/// `reconcile`, so a second call with the same definitions is idempotent.
fn definitions() -> &'static Mutex<BTreeMap<String, Value>> {
    static DEFINITIONS: OnceLock<Mutex<BTreeMap<String, Value>>> = OnceLock::new();
    DEFINITIONS.get_or_init(|| Mutex::new(BTreeMap::new()))
}

fn waiting_state() -> &'static Mutex<BTreeMap<String, Value>> {
    static WAITING: OnceLock<Mutex<BTreeMap<String, Value>>> = OnceLock::new();
    WAITING.get_or_init(|| Mutex::new(BTreeMap::new()))
}

static RECONCILING: AtomicBool = AtomicBool::new(false);

/// Record that an instance is running and what its artifact provides. Called from
/// `services::start`/`services::replace` once the instance exists.
pub fn note_started(name: &str) {
    let Some(interfaces) = install_lookup(name) else { return };
    providers().lock().unwrap_or_else(|e| e.into_inner()).insert(name.to_string(), interfaces.provides());
}

/// Record that a component is no longer running: what it provided stops being served.
pub fn note_stopped(name: &str) {
    providers().lock().unwrap_or_else(|e| e.into_inner()).remove(name);
}

/// The served set as the node currently understands it: the supervisor's registry plus every instance
/// the services registry reports as running (a component started by `services start`, not by
/// `supervise`, still provides what it exports).
pub fn served() -> Served {
    current_served()
}

fn current_served() -> Served {
    let mut served = Served::default();
    for row in services::status(None).as_array().cloned().unwrap_or_default() {
        let Some(name) = row["name"].as_str() else { continue };
        let state = row["state"].as_str().unwrap_or_default();
        if state == "running" || state == "backoff" || state == "starting" {
            // Memoized per process on the first sight of a running name: the fallback reads and hashes
            // the installed artifact, which is not something to do once per plan for an 8 MB component.
            let known = providers().lock().unwrap_or_else(|e| e.into_inner()).get(name).cloned();
            let provides = match known {
                Some(provides) => provides,
                None => {
                    let provides = install_lookup(name).map(|interfaces| interfaces.provides()).unwrap_or_default();
                    providers().lock().unwrap_or_else(|e| e.into_inner()).insert(name.to_string(), provides.clone());
                    provides
                }
            };
            served.add(name, &provides);
        }
    }
    served
}

/// The name a waiting definition is stuck on, as `services status` prints it.
pub fn pending(name: &str) -> Option<Value> {
    waiting_state().lock().unwrap_or_else(|e| e.into_inner()).get(name).cloned()
}

pub fn pending_entries() -> Vec<(String, Value)> {
    waiting_state().lock().unwrap_or_else(|e| e.into_inner()).iter().map(|(name, waiting)| (name.clone(), waiting.clone())).collect()
}

/// A definition that was stopped is no longer wanted: remove it from the supervisor's set so a
/// reconcile does not start it again.
///
/// This is the difference between "the supervisor manages this component" and "an operator stopped it".
/// Without it, `services stop` followed by anything that kicks the supervisor (another component
/// starting) restarted the service the operator had just stopped - which is what
/// `scripts/test-service-component.lua`'s `restart` check caught: `stop` then `start` answered
/// `already_running` because the reconcile had already restarted it.
pub fn forget(name: &str) {
    definitions().lock().unwrap_or_else(|e| e.into_inner()).remove(name);
    waiting_state().lock().unwrap_or_else(|e| e.into_inner()).remove(name);
}

/// Re-plan after something changed: a provider came up, a component stopped, a definition was added.
///
/// Re-entrant by construction, because `services::start` calls it: a nested call during a reconcile
/// only records that another pass is wanted, and the outer loop takes it.
pub fn kick() {
    if RECONCILING.swap(true, Ordering::SeqCst) {
        return;
    }
    let _ = std::panic::catch_unwind(reconcile_registered);
    RECONCILING.store(false, Ordering::SeqCst);
}

fn reconcile_registered() {
    let definitions: Vec<Value> = definitions().lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
    if definitions.is_empty() {
        return;
    }
    let _ = supervise(&definitions);
}

/// `services supervise {definitions: [...]}`: start everything whose imports are served, report what
/// still waits, and remember both so a later start can unblock the wait.
pub fn reconcile(request: &Value) -> Value {
    let requested: Vec<Value> = match request.get("definitions") {
        Some(Value::Array(items)) => items.clone(),
        Some(_) => return json!({"ok": false, "error": "invalid_supervise_definitions"}),
        None => definitions().lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect(),
    };
    for definition in &requested {
        let Some(name) = definition.get("name").and_then(Value::as_str) else {
            return json!({"ok": false, "error": "invalid_service_definition"});
        };
        definitions().lock().unwrap_or_else(|e| e.into_inner()).insert(name.to_string(), definition.clone());
    }
    if RECONCILING.swap(true, Ordering::SeqCst) {
        // Another pass is running and will see the definitions we just registered.
        return json!({"ok": true, "deferred": true});
    }
    let answer = std::panic::catch_unwind(|| supervise(&requested));
    RECONCILING.store(false, Ordering::SeqCst);
    match answer {
        Ok(answer) => answer,
        Err(_) => json!({"ok": false, "error": "supervise_panicked"}),
    }
}

fn supervise(definitions: &[Value]) -> Value {
    let names: Vec<String> = definitions.iter().filter_map(|d| d.get("name").and_then(Value::as_str).map(str::to_string)).collect();
    let by_name: BTreeMap<String, Value> = definitions
        .iter()
        .filter_map(|d| d.get("name").and_then(Value::as_str).map(|n| (n.to_string(), d.clone())))
        .collect();
    let mut started: BTreeMap<String, Value> = BTreeMap::new();
    let mut refusals: BTreeMap<String, Value> = BTreeMap::new();
    // One plan, then one start per name the plan allows, then a plan again: a start can serve an
    // interface the previous plan did not know about (a provider whose imports were themselves
    // satisfied in the pass before), and a fixed point is the only honest stopping rule.
    for _ in 0..names.len().max(1) + 1 {
        let served = current_served();
        let plan = plan(&names, &served);
        // Remember what each stopped definition waits for, so `status` can say it.
        {
            let mut waiting = waiting_state().lock().unwrap_or_else(|e| e.into_inner());
            for name in &names {
                match plan.waiting.get(name) {
                    Some(stuck) => {
                        waiting.insert(
                            name.clone(),
                            json!({
                                "waiting_for": stuck.waiting_for,
                                "reason": stuck.reason,
                            }),
                        );
                    }
                    None => {
                        waiting.remove(name);
                    }
                }
            }
        }
        if plan.start.is_empty() {
            break;
        }
        for name in &plan.start {
            let Some(definition) = by_name.get(name) else { continue };
            let answer = services::start(definition);
            if answer["ok"] == json!(true) {
                started.insert(name.clone(), answer);
            } else {
                refusals.insert(name.clone(), answer);
            }
        }
        if started.is_empty() {
            break;
        }
    }
    // What was already running and stays running: a boot that runs twice must be able to say "it was
    // already up" per name, which is what the registry's `autostart` reported before the supervisor
    // existed and what its callers (and its test) still read.
    let served_now = current_served();
    let already_running: Vec<Value> = names
        .iter()
        .filter(|name| served_now.running.contains(*name) && !started.contains_key(*name))
        .map(|name| {
            let row = services::status(Some(name));
            json!({"name": name, "state": row["state"], "sha256": row["sha256"], "instance": row["instance"]})
        })
        .collect();
    let waiting: Vec<Value> = pending_entries()
        .into_iter()
        .filter(|(name, _)| names.iter().any(|wanted| wanted == name))
        .map(|(name, waiting)| {
            json!({
                "name": name,
                "state": "waiting",
                "waiting_for": waiting["waiting_for"],
                "reason": waiting["reason"],
            })
        })
        .collect();
    json!({
        "ok": refusals.is_empty(),
        "started": started,
        "already_running": already_running,
        "refused": refusals,
        "waiting": waiting,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn interfaces(imports: &[&str], exports: &[&str]) -> Interfaces {
        Interfaces {
            contract: crate::imports::Contract::V1,
            imports: imports.iter().map(|s| s.to_string()).collect(),
            exports: exports.iter().map(|s| s.to_string()).collect(),
        }
    }

    /// The core of lesson 3: a consumer written *after* its provider, and one written *before* it,
    /// both start, in an order the configuration cannot influence.
    #[test]
    fn a_provider_starts_before_its_consumer_whatever_the_definition_order() {
        let look = |name: &str| -> Option<Interfaces> {
            match name {
                "reader" => Some(interfaces(&["wa:kernel/kv@0.1.0", "wa:vision/text-reader@0.1.0"], &[])),
                "vision" => Some(interfaces(&["wa:kernel/kv@0.1.0"], &["wa:vision/text-reader@0.1.0"])),
                _ => None,
            }
        };
        for order in [vec!["reader", "vision"], vec!["vision", "reader"]] {
            let names: Vec<String> = order.iter().map(|s| s.to_string()).collect();
            let plan = plan_with(&names, &Served::default(), &look);
            assert_eq!(plan.start, vec!["vision".to_string(), "reader".to_string()], "order {order:?}");
            assert!(plan.waiting.is_empty(), "{plan:?}");
        }
    }

    #[test]
    fn what_waits_says_which_interface_and_why() {
        let look = |name: &str| -> Option<Interfaces> {
            match name {
                "reader" => Some(interfaces(&["wa:vision/text-reader@0.1.0"], &[])),
                "missing" => None,
                _ => None,
            }
        };
        let names = vec!["reader".to_string(), "missing".to_string()];
        let plan = plan_with(&names, &Served::default(), &look);
        assert!(plan.start.is_empty());
        assert_eq!(plan.waiting["reader"].waiting_for, vec!["wa:vision/text-reader@0.1.0".to_string()]);
        assert_eq!(plan.waiting["reader"].reason, "imports_not_served");
        assert_eq!(plan.waiting["missing"].reason, "not_installed");
        assert!(plan.waiting["missing"].waiting_for.is_empty());
        // A provider that is already running serves the interface at once.
        let mut served = Served::default();
        served.add("vision", &interfaces(&[], &["wa:vision/text-reader@0.1.0"]).provides());
        let plan = plan_with(&names, &served, &look);
        assert_eq!(plan.start, vec!["reader".to_string()]);
        assert_eq!(plan.waiting["missing"].reason, "not_installed");
        // And nothing that is already running is started twice.
        let mut served = served.clone();
        served.add("reader", &BTreeSet::new());
        let plan = plan_with(&names, &served, &look);
        assert!(plan.start.is_empty());
        assert!(!plan.waiting.contains_key("reader"));
    }

    #[test]
    fn a_cycle_neither_starts_nor_hangs() {
        // Two components that each need what the other exports: neither can start, both say what they
        // wait for, and planning terminates. An operator reading `status` sees a cycle, not a spin.
        let look = |name: &str| -> Option<Interfaces> {
            match name {
                "a" => Some(interfaces(&["wa:provider/b@0.1.0"], &["wa:provider/a@0.1.0"])),
                "b" => Some(interfaces(&["wa:provider/a@0.1.0"], &["wa:provider/b@0.1.0"])),
                _ => None,
            }
        };
        let names = vec!["a".to_string(), "b".to_string()];
        let plan = plan_with(&names, &Served::default(), &look);
        assert!(plan.start.is_empty(), "{plan:?}");
        assert_eq!(plan.waiting["a"].waiting_for, vec!["wa:provider/b@0.1.0".to_string()]);
        assert_eq!(plan.waiting["b"].waiting_for, vec!["wa:provider/a@0.1.0".to_string()]);
    }

    #[test]
    fn the_kernel_interfaces_are_never_a_reason_to_wait() {
        let look = |name: &str| -> Option<Interfaces> {
            (name == "plain").then(|| interfaces(&["wa:kernel/kv@0.1.0", "wasi:io/streams@0.2.3", "wa:bus/publisher@0.1.0"], &[]))
        };
        let plan = plan_with(&["plain".to_string()], &Served::default(), &look);
        assert_eq!(plan.start, vec!["plain".to_string()]);
        assert!(plan.waiting.is_empty());
    }
}
