//! Revocable registrations: everything a component registers through the kernel is a handle, and the
//! handle dies with the instance that made it (`docs/KERNEL.md`, lesson 2).
//!
//! The problem this solves is not "free the memory". It is exactness on replacement: `wa dev` and a
//! transactional upgrade start a **second** instance of the same name before the old one stops
//! (`dev.rs`), and both carry the same component name, the same grants and the same state. Anything a
//! provider keys by component *name* - a bus subscription, a queue grant, a timer registration -
//! would then be revoked "for the name" at the moment the old instance stops, which is precisely when
//! the new instance is alive and using it. The observed failure on 06/11 was the same shape from the
//! other side: a stopped instance's bus subscription kept receiving events because nothing revoked it.
//!
//! So an instance gets an identity of its own:
//!
//! * [`Ledger::open_instance`] hands out `{name, generation, token}`. The **name** is the installed
//!   component (what the ACL, the policy and the log use, and what a guest is attributed to); the
//!   **generation** counts instances of that name in this process; the **token** (`name#generation`)
//!   is the key a provider stores so it can revoke *one instance* without touching the other.
//! * Everything registered is entered here with its owner generation and, when the provider needs one,
//!   a cancel closure that the ledger runs when the registration is revoked. The ledger owns revoking;
//!   the provider owns the effect.
//! * `services::stop` revokes the whole owner (a component that stopped keeps nothing).
//!   `dev`/`install` revoke **one generation** (the instance that lost), leaving the winner's rows.
//!
//! What is deliberately not here: persistence (a registration is a live thing; the durable half of a
//! subscription is the bus's own retention), a scheduler (a timer is a registration whose effect is a
//! thread the registrant owns), and cross-process revocation (each process has its own ledger and its
//! own instances; that is what the name+g generation is scoped to).
//!
//! The kinds below are the seams the kernel actually has today plus the two a provider adds next:
//! `Tool` and `Route` exist so a component that registers a tool through the broker has somewhere to
//! put the handle *before* the registry is written, rather than a plan that has to be remembered.

use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

/// What a component registered.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    /// A `wa:bus` subscription: one pattern, one stream per subscriber.
    BusSubscription,
    /// A `wa:queue` interface over a granted namespace (a consumer/producer grant in practice).
    QueueConsumer,
    /// A timer the kernel fires on a component's behalf. No kernel interface offers one today (a
    /// 0.2 guest awaits `wasi:clocks`); this is the handle a proactive timer provider registers.
    Timer,
    /// A tool a component offers through the broker (`wa:mcp/server` today is per-call, so nothing
    /// registers one yet; a long-lived provider would).
    Tool,
    /// A route (an HTTP path served through a `listen` grant): the same seam as `Tool`.
    Route,
}

impl Kind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Kind::BusSubscription => "bus_subscription",
            Kind::QueueConsumer => "queue_consumer",
            Kind::Timer => "timer",
            Kind::Tool => "tool",
            Kind::Route => "route",
        }
    }

    fn all() -> [Kind; 5] {
        [Kind::BusSubscription, Kind::QueueConsumer, Kind::Timer, Kind::Tool, Kind::Route]
    }
}

/// The identity of one running instance: the name its grants and attribution use, the generation that
/// distinguishes it from the instance it replaces, and the token a provider keys its rows by.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Instance {
    pub name: String,
    pub generation: u64,
    pub token: String,
}

impl Instance {
    pub fn to_json(&self) -> Value {
        json!({"name": self.name, "generation": self.generation, "token": self.token})
    }
}

/// What `register` returns and what `revoke` takes: an opaque handle, not a provider-specific id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Handle {
    pub owner: String,
    pub generation: u64,
    pub id: u64,
    pub kind: Kind,
}

impl Handle {
    pub fn to_json(&self) -> Value {
        json!({"owner": self.owner, "generation": self.generation, "id": self.id, "kind": self.kind.as_str()})
    }
}

/// The effect of revoking one registration, owned by the provider that registered it.
pub type Cancel = Box<dyn FnOnce() + Send>;

struct Entry {
    kind: Kind,
    /// The instance that registered it: the whole point of the ledger.
    generation: u64,
    /// What it is, in the provider's words, for `status` and for a log line: a pattern, a namespace, a
    /// timer name. Never a payload, never a secret.
    detail: String,
    cancel: Option<Cancel>,
}

/// The node's ledger. One per process, like the bus and the queue it tracks.
pub struct Ledger {
    next_id: AtomicU64,
    generations: Mutex<BTreeMap<String, u64>>,
    owners: Mutex<BTreeMap<String, BTreeMap<u64, Entry>>>,
}

impl Default for Ledger {
    fn default() -> Ledger {
        Ledger { next_id: AtomicU64::new(1), generations: Mutex::new(BTreeMap::new()), owners: Mutex::new(BTreeMap::new()) }
    }
}

impl Ledger {
    pub fn new() -> Ledger {
        Ledger::default()
    }

    /// Open an instance of `name`: the next generation, and the token providers key by. Monotonic per
    /// name, never reused, so a stale token can never collide with a live one.
    pub fn open_instance(&self, name: &str) -> Instance {
        let mut generations = self.generations.lock().unwrap_or_else(|e| e.into_inner());
        let generation = generations.entry(name.to_string()).or_insert(0);
        *generation += 1;
        let generation = *generation;
        Instance { name: name.to_string(), generation, token: format!("{name}#{generation}") }
    }

    /// The last generation opened for `name` (0 when none).
    pub fn generation_of(&self, name: &str) -> u64 {
        self.generations.lock().unwrap_or_else(|e| e.into_inner()).get(name).copied().unwrap_or(0)
    }

    /// Record one registration. `cancel` is the provider's own revocation - the ledger runs it when the
    /// registration is revoked, so "revoked" cannot mean only "forgotten".
    pub fn register(&self, instance: &Instance, kind: Kind, detail: &str, cancel: Option<Cancel>) -> Handle {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let handle = Handle { owner: instance.name.clone(), generation: instance.generation, id, kind };
        self.owners
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry(instance.name.clone())
            .or_default()
            .insert(id, Entry { kind, generation: instance.generation, detail: bounded(detail), cancel });
        handle
    }

    /// Revoke one handle. `true` when it was there (and its cancel ran).
    pub fn revoke(&self, handle: &Handle) -> bool {
        let entry = self
            .owners
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get_mut(&handle.owner)
            .and_then(|by_id| by_id.remove(&handle.id));
        let Some(entry) = entry else { return false };
        run(entry.cancel);
        true
    }

    /// Revoke one instance's registrations, leaving any other generation of the same name alone. This
    /// is the hot-swap rule: the instance that lost goes, the instance that won keeps its rows.
    pub fn revoke_generation(&self, owner: &str, generation: u64) -> usize {
        let taken = {
            let mut owners = self.owners.lock().unwrap_or_else(|e| e.into_inner());
            let Some(by_id) = owners.get_mut(owner) else { return 0 };
            let ids: Vec<u64> = by_id.iter().filter(|(_, entry)| entry.generation == generation).map(|(id, _)| *id).collect();
            let mut taken = Vec::with_capacity(ids.len());
            for id in ids {
                if let Some(entry) = by_id.remove(&id) {
                    taken.push(entry.cancel);
                }
            }
            if by_id.is_empty() {
                owners.remove(owner);
            }
            taken
        };
        let count = taken.len();
        // Cancels run outside the ledger's lock: a cancel takes the bus's or the queue's lock, and
        // holding both in the other order is how a deadlock is built.
        for cancel in taken {
            run(cancel);
        }
        count
    }

    /// Revoke everything one component holds, every generation. The stop path: a component that is not
    /// running keeps nothing.
    pub fn revoke_owner(&self, owner: &str) -> usize {
        let taken = self.owners.lock().unwrap_or_else(|e| e.into_inner()).remove(owner).map(|by_id| by_id.into_values().map(|entry| entry.cancel).collect::<Vec<_>>()).unwrap_or_default();
        let count = taken.len();
        for cancel in taken {
            run(cancel);
        }
        count
    }

    /// How many registrations one generation holds.
    pub fn count_generation(&self, owner: &str, generation: u64) -> usize {
        self.owners
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(owner)
            .map(|by_id| by_id.values().filter(|entry| entry.generation == generation).count())
            .unwrap_or(0)
    }

    /// How many registrations one component holds, across generations.
    pub fn count_owner(&self, owner: &str) -> usize {
        self.owners.lock().unwrap_or_else(|e| e.into_inner()).get(owner).map(|by_id| by_id.len()).unwrap_or(0)
    }

    /// One component's registrations as `(handle, kind, detail)`: what `status` and the swap test read.
    pub fn entries(&self, owner: &str) -> Vec<(Handle, Kind, String)> {
        let owners = self.owners.lock().unwrap_or_else(|e| e.into_inner());
        let Some(by_id) = owners.get(owner) else { return Vec::new() };
        by_id
            .iter()
            .map(|(id, entry)| (Handle { owner: owner.to_string(), generation: entry.generation, id: *id, kind: entry.kind }, entry.kind, entry.detail.clone()))
            .collect()
    }

    /// Counts only: per kind and per component. Safe to put in `/health`.
    pub fn status(&self) -> Value {
        let owners = self.owners.lock().unwrap_or_else(|e| e.into_inner());
        let mut kinds = BTreeMap::new();
        for kind in Kind::all() {
            kinds.insert(kind.as_str(), 0usize);
        }
        let mut total = 0;
        let mut components = Vec::new();
        for (owner, by_id) in owners.iter() {
            for entry in by_id.values() {
                total += 1;
                *kinds.entry(entry.kind.as_str()).or_insert(0) += 1;
            }
            components.push(json!({
                "component": owner,
                "registrations": by_id.len(),
                "generations": by_id.values().map(|e| e.generation).collect::<std::collections::BTreeSet<u64>>().into_iter().collect::<Vec<u64>>(),
            }));
        }
        json!({"total": total, "kinds": kinds, "components": components})
    }
}

fn run(cancel: Option<Cancel>) {
    if let Some(cancel) = cancel {
        cancel();
    }
}

fn bounded(detail: &str) -> String {
    detail.chars().filter(|c| !c.is_control()).take(120).collect()
}

/// The node's ledger (one per process, like the bus and the queue).
pub fn node() -> &'static Ledger {
    static NODE: OnceLock<Ledger> = OnceLock::new();
    NODE.get_or_init(Ledger::new)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicU32;
    use std::sync::Arc;

    #[test]
    fn a_generation_is_revoked_without_touching_the_instance_that_replaced_it() {
        let ledger = Ledger::new();
        let first = ledger.open_instance("svc");
        let second = ledger.open_instance("svc");
        assert_eq!((first.generation, second.generation), (1, 2));
        assert_eq!(first.token, "svc#1");
        assert_ne!(first.token, second.token);
        let ran = Arc::new(AtomicU32::new(0));
        for (instance, pattern) in [(&first, "app.in"), (&first, "app.out"), (&second, "app.in")] {
            let counter = ran.clone();
            ledger.register(instance, Kind::BusSubscription, pattern, Some(Box::new(move || {
                counter.fetch_add(1, Ordering::SeqCst);
            })));
        }
        assert_eq!(ledger.count_generation("svc", 1), 2);
        assert_eq!(ledger.count_generation("svc", 2), 1);
        assert_eq!(ledger.revoke_generation("svc", 1), 2);
        assert_eq!(ran.load(Ordering::SeqCst), 2, "each revoked registration ran its own cancel");
        assert_eq!(ledger.count_generation("svc", 1), 0);
        assert_eq!(ledger.count_generation("svc", 2), 1, "the live instance keeps its row");
        // Stopping the component for good takes everything, both generations.
        assert_eq!(ledger.revoke_owner("svc"), 1);
        assert_eq!(ledger.count_owner("svc"), 0);
    }

    #[test]
    fn a_revoked_handle_is_revoked_once_and_an_unknown_one_is_an_answer_not_a_panic() {
        let ledger = Ledger::new();
        let instance = ledger.open_instance("svc");
        let handle = ledger.register(&instance, Kind::Timer, "heartbeat", None);
        assert!(ledger.revoke(&handle));
        assert!(!ledger.revoke(&handle), "the second revoke is false, not a double cancel");
        let ghost = Handle { owner: "nobody".into(), generation: 1, id: 999, kind: Kind::Tool };
        assert!(!ledger.revoke(&ghost));
        assert_eq!(ledger.revoke_generation("nobody", 1), 0);
        assert_eq!(ledger.revoke_owner("nobody"), 0);
    }

    #[test]
    fn status_counts_by_kind_and_never_carries_a_payload() {
        let ledger = Ledger::new();
        let instance = ledger.open_instance("wa-whatsapp");
        ledger.register(&instance, Kind::BusSubscription, "whatsapp.inbox", None);
        ledger.register(&instance, Kind::QueueConsumer, "whatsapp.outbox", None);
        ledger.register(&instance, Kind::Tool, "send\nwith a newline", None);
        let status = ledger.status();
        assert_eq!(status["total"], 3);
        let kinds = &status["kinds"];
        assert_eq!(kinds["bus_subscription"], 1);
        assert_eq!(kinds["queue_consumer"], 1);
        assert_eq!(kinds["tool"], 1);
        assert_eq!(kinds["timer"], 0);
        // A detail is bounded and stripped of control characters: a label cannot split a log line.
        let tools = ledger.entries("wa-whatsapp");
        assert_eq!(tools.len(), 3);
        assert!(tools.iter().all(|(_, _, detail)| !detail.contains('\n')));
        for kind in Kind::all() {
            assert!(!kind.as_str().is_empty());
        }
    }
}
