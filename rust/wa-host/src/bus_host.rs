//! The bus in the host: one `wa_bus::Bus` per node, served to components as `wa:bus`.
//!
//! The library (`rust/wa-bus`) is the whole design — topics, patterns, bounded buffers with an
//! explicit overflow policy, revocable registrations, optional last-N retention, an `Access` trait.
//! This module is the node half of `docs/BUS.md` "Integration into wa-host":
//!
//! 1. **One bus per node**, created here and shared by every component runner (the same shape as the
//!    tool/route registries). `node()` is the process-wide handle; a test builds its own with
//!    [`BusHost::new`].
//! 2. **The ACL comes from the manifest grant**, not from the guest: `{"bus": {"publish": [..],
//!    "subscribe": [..]}}` in the component's manifest. Every registration rebuilds one
//!    `NamespaceAcl` from every installed component's grants, because the bus takes an
//!    `Arc<dyn Access>` and rebuilding is how a stopped component's grant stops applying. The
//!    default stays "own namespace only" — `NamespaceAcl`'s own rule — so a component that declares
//!    nothing can still publish and subscribe inside `whatsapp.*` if its installed name is
//!    `whatsapp`.
//! 3. **`source` is set by the host**, never by the guest: it is the installed component name, and
//!    it is also what the ACL checks.
//! 4. **Delivery to a guest is a stream**: `subscriber.subscribe` returns a `stream<event>`; a pump
//!    thread per subscription moves events from the `wa_bus::Subscription` into a small queue the
//!    producer hands to the guest, and wakes the guest's task through the shared `Notify`. Dropping
//!    the stream (or the component stopping) stops the pump and drops the `Subscription`, which is
//!    the unsubscribe.
//! 5. **Revocation on stop**: `services::stop` calls [`unregister`], which revokes every
//!    subscription the component owns and removes its grants. A stopped component is never handed
//!    one more event (`docs/BUS.md`, "Revocation").
//!
//! What is deliberately not here: cross-node fan-out (the relay's job), exactly-once, and a
//! per-subscriber cursor (that would make the bus a queue). Retention is enabled per exact topic by
//! the node (`enable_retention`), because a topic with no retention is the default.

use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use wasmtime::AsContextMut as _;
use wa_bus::{
    Action, Bus, BusError as LibraryError, Event as LibraryEvent, NamespaceAcl, OverflowPolicy,
    SubscribeOptions, Subscription, Topic,
};

wasmtime::component::bindgen!({
    world: "event-bus",
    path: "../../wit/bus",
    // `subscribe` is a synchronous call that hands the guest a `stream`, so the host needs the store
    // to create the transmit handle (the same rule `wa:kernel@0.2`'s `socket.messages` follows).
    imports: {
        "wa:bus/subscriber.subscribe": store | trappable,
    },
});

use wa::bus::types::{Error as BusFault, Event as GuestEvent, Overflow, SubscriptionOptions};

/// The topic the queue sweeper publishes its alerts to (`docs/QUEUE.md`, "Alert delivery"). It is
/// inside the bus's own namespace, so no component can publish there unless it is named `kernel`.
pub const QUEUE_ALERT_TOPIC: &str = "kernel.queue.alert";

/// How often a subscription pump asks its `wa_bus::Subscription` for events. The bus has no blocking
/// `recv` (a receiver that must wait is a queue, not a bus), so the pump is a fast poll; 5 ms is
/// below a person's perception and above a spin.
const PUMP_TICK: Duration = Duration::from_millis(5);

/// One component's declared bus grants, as the manifest writes them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Grants {
    pub publish: Vec<String>,
    pub subscribe: Vec<String>,
}

impl Grants {
    /// Read `capabilities.bus`. Absent means "own namespace only", which is the library default and
    /// needs no entry here. A malformed grant is an error, never a silent empty grant: a component
    /// installed with `{"bus": "everything"}` must be refused by the loader, not run with nothing.
    pub fn from_manifest(manifest: &Value) -> Result<Grants, String> {
        let Some(bus) = manifest.get("capabilities").and_then(|c| c.get("bus")) else {
            return Ok(Grants::default());
        };
        let object = bus.as_object().ok_or_else(|| "invalid_component_grant:bus".to_string())?;
        let list = |field: &str| -> Result<Vec<String>, String> {
            let Some(value) = object.get(field) else { return Ok(Vec::new()) };
            let items = value.as_array().ok_or_else(|| format!("invalid_component_grant:bus.{field}"))?;
            let mut out = Vec::new();
            for item in items {
                let text = item.as_str().ok_or_else(|| format!("invalid_component_grant:bus.{field}"))?;
                // A pattern is validated by the bus itself; this only bounds what a manifest can be.
                if text.is_empty() || text.len() > 256 || items.len() > 64 {
                    return Err(format!("invalid_component_grant:bus.{field}"));
                }
                out.push(text.to_string());
            }
            Ok(out)
        };
        Ok(Grants { publish: list("publish")?, subscribe: list("subscribe")? })
    }
}

/// The node's bus and the grants the ACL is built from.
pub struct BusHost {
    bus: Bus,
    grants: Mutex<BTreeMap<String, Grants>>,
}

impl BusHost {
    pub fn new() -> BusHost {
        BusHost { bus: Bus::with_access(Arc::new(NamespaceAcl::new())), grants: Mutex::new(BTreeMap::new()) }
    }

    pub fn bus(&self) -> &Bus {
        &self.bus
    }

    /// Record (or replace) a component's grants and rebuild the ACL from scratch. Called from
    /// `services::start`, after the manifest grant has been checked against the manifest itself.
    pub fn register(&self, component: &str, manifest: &Value) -> Result<Grants, String> {
        let grants = Grants::from_manifest(manifest)?;
        // Validate every pattern now, so a bad manifest is a refusal at install time and not a
        // refusal at the first subscribe, which nobody watches.
        for (action, patterns) in [(Action::Publish, &grants.publish), (Action::Subscribe, &grants.subscribe)] {
            for pattern in patterns {
                Name::check(pattern).map_err(|e| format!("invalid_component_grant:bus.{}:{e}", action.as_str()))?;
            }
        }
        self.grants
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(component.to_string(), grants.clone());
        self.rebuild_acl();
        Ok(grants)
    }

    /// Forget a component: revoke every subscription it owns **and** its grants. A stopped component
    /// keeps nothing (`docs/BUS.md`, "Revocation").
    pub fn unregister(&self, component: &str) -> usize {
        let removed = self
            .grants
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(component);
        self.rebuild_acl();
        let revoked = self.bus.revoke_owner(component);
        let _ = removed;
        revoked
    }

    fn rebuild_acl(&self) {
        let mut acl = NamespaceAcl::new();
        for (component, grants) in self.grants.lock().unwrap_or_else(|e| e.into_inner()).iter() {
            for pattern in &grants.publish {
                let _ = acl.grant(component, Action::Publish, pattern);
            }
            for pattern in &grants.subscribe {
                let _ = acl.grant(component, Action::Subscribe, pattern);
            }
        }
        self.bus.set_access(Arc::new(acl));
    }

    /// Keep the last `retain` events of one topic in `namespace` (a component's `b/` sub-namespace,
    /// or a node-level store). Idempotent; a topic with retention already enabled keeps the newest
    /// setting.
    pub fn enable_retention(&self, topic: &str, retain: usize, namespace: Arc<dyn wa_bus::Kv>) -> Result<(), String> {
        self.bus.enable_durable(topic, retain, namespace).map_err(|e| e.to_string())
    }

    /// Publish as `component`. `source` is overwritten with the component name: a guest never names
    /// itself, and the ACL checks the same value (`docs/BUS.md`, "Envelope").
    pub fn publish(&self, component: &str, mut event: GuestEvent) -> Result<Report, BusFault> {
        let topic = Topic::parse(&event.topic).map_err(fault_from_topic)?;
        if event.id == 0 {
            event.id = 0; // the library assigns one; 0 is its "unassigned" sentinel
        }
        let mut library = LibraryEvent {
            id: wa_bus::EventId(event.id),
            topic,
            ts_ms: event.ts_ms,
            source: component.to_string(),
            schema: wa_bus::Schema::new(&event.schema, event.schema_version),
            payload: event.payload,
            trace: event.trace,
        };
        // A guest-supplied `source` is not an error, it is ignored: the kernel owns the field.
        library.source = component.to_string();
        match self.bus.publish(library) {
            Ok(outcome) => Ok(Report {
                matched: outcome.matched as u32,
                delivered: outcome.delivered as u32,
                dropped: outcome.dropped as u32,
                id: outcome.id.0,
            }),
            Err(error) => Err(fault(error)),
        }
    }

    /// Subscribe as `component`, inside the granted patterns. `replay` asks for retained events
    /// first and is refused for a topic with no retention, exactly as the library does.
    pub fn subscribe(
        &self,
        component: &str,
        pattern: &str,
        options: SubscribeOptions,
        replay: Option<usize>,
    ) -> Result<Subscription, BusFault> {
        let result = match replay {
            Some(limit) => self.bus.subscribe_replaying(component, pattern, options, limit),
            None => self.bus.subscribe(component, pattern, options),
        };
        result.map_err(fault)
    }

    /// The node's own publisher, for host-generated facts (the queue sweeper's alerts). It goes
    /// through the same ACL, as `kernel`: a node that cannot publish its own facts is a bug worth
    /// hearing about.
    pub fn publish_node_fact(&self, topic: &str, schema: &str, payload: Vec<u8>) -> Result<Report, BusFault> {
        let topic = Topic::parse(topic).map_err(fault_from_topic)?;
        let event = LibraryEvent::new(topic, "kernel", schema, payload);
        self.bus
            .publish(event)
            .map(|outcome| Report {
                matched: outcome.matched as u32,
                delivered: outcome.delivered as u32,
                dropped: outcome.dropped as u32,
                id: outcome.id.0,
            })
            .map_err(fault)
    }

    /// Subscriptions per owner, for `status`. Counts and patterns only, never a payload.
    pub fn status(&self) -> Value {
        let subscriptions: Vec<Value> = self
            .bus
            .subscriptions()
            .iter()
            .map(|sub| json!({"owner": sub.owner, "pattern": sub.pattern, "queued": sub.queued, "capacity": sub.capacity, "dropped": sub.dropped}))
            .collect();
        let grants = self.grants.lock().unwrap_or_else(|e| e.into_inner());
        json!({
            "subscriptions": subscriptions,
            "durable_topics": self.bus.durable_topics().iter().map(|(t, n)| json!({"topic": t, "retain": n})).collect::<Vec<_>>(),
            "grants": grants.iter().map(|(component, g)| json!({
                "component": component,
                "publish": g.publish,
                "subscribe": g.subscribe,
            })).collect::<Vec<_>>(),
        })
    }
}

/// What one publish did, reduced to what the WIT report carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Report {
    pub id: u64,
    pub matched: u32,
    pub delivered: u32,
    pub dropped: u32,
}

// `NamespaceAcl::grant` parses the pattern itself; `Name::check` is the validation without a
// subscription, so a bad manifest fails at install time.
struct Name;
impl Name {
    fn check(pattern: &str) -> Result<(), String> {
        wa_bus::Pattern::parse(pattern).map(|_| ()).map_err(|e| e.to_string())
    }
}

fn fault_from_topic(error: wa_bus::TopicError) -> BusFault {
    BusFault::Refused(format!("invalid_topic:{error}"))
}

/// The library's refusal in the guest's vocabulary: a denial is `refused` (the guest may report it),
/// a store failure is `failed` (never a silent success), everything else is `failed` with a reason
/// word rather than a payload.
fn fault(error: LibraryError) -> BusFault {
    match error {
        LibraryError::Denied { .. } => BusFault::Refused(error.to_string()),
        LibraryError::Topic(_) | LibraryError::BadOptions(_) => BusFault::Refused(error.to_string()),
        LibraryError::ReplayNotDurable(_) | LibraryError::ReplayNeedsExactTopic(_) => BusFault::Refused(error.to_string()),
        LibraryError::Store(_) => BusFault::Failed(error.to_string()),
    }
}

fn overflow(policy: Overflow) -> OverflowPolicy {
    match policy {
        Overflow::DropOldest => OverflowPolicy::DropOldest,
        Overflow::DropNewest => OverflowPolicy::DropNewest,
        Overflow::Block => OverflowPolicy::Block,
    }
}

// ---- the node singleton ---------------------------------------------------------------------------

/// The node's bus. One per process, shared by every component runner and by the queue sweeper.
pub fn node() -> &'static BusHost {
    static NODE: OnceLock<BusHost> = OnceLock::new();
    NODE.get_or_init(BusHost::new)
}

/// Record a component's bus grants on the node bus. `services::start` calls this before the instance
/// exists, so a manifest that declares a grant it cannot parse is refused before anything runs.
pub fn register(component: &str, manifest: &Value) -> Result<Grants, String> {
    node().register(component, manifest)
}

/// Revoke everything a stopped component holds. Returns how many subscriptions were revoked.
pub fn unregister(component: &str) -> usize {
    node().unregister(component)
}

// ---- delivery: a subscription as a guest stream ---------------------------------------------------

/// The shared half of one stream: what the pump writes, what the guest's producer reads.
struct Channel {
    queue: Mutex<std::collections::VecDeque<LibraryEvent>>,
    notify: Arc<crate::service_io::Notify>,
    closed: AtomicBool,
    /// Set by the producer when the guest drops the stream; the pump sees it, exits and drops the
    /// `wa_bus::Subscription`, which unsubscribes.
    stop: AtomicBool,
    capacity: usize,
}

impl Channel {
    fn push(&self, event: LibraryEvent) {
        {
            let mut queue = self.queue.lock().unwrap_or_else(|e| e.into_inner());
            // Bounded like the bus buffer: a guest that stops reading cannot make the host hold an
            // unbounded number of events. The loss is counted by the bus, which is where the
            // subscription's own `dropped` counter lives.
            if queue.len() >= self.capacity {
                queue.pop_front();
            }
            queue.push_back(event);
        }
        self.notify.notify();
    }

    fn pop(&self) -> Option<LibraryEvent> {
        self.queue.lock().unwrap_or_else(|e| e.into_inner()).pop_front()
    }
}

/// Start the pump for one subscription and return the channel the guest's stream reads from.
fn pump(subscription: Subscription, capacity: usize) -> Arc<Channel> {
    let channel = Arc::new(Channel {
        queue: Mutex::new(std::collections::VecDeque::new()),
        notify: crate::service_io::Notify::new(),
        closed: AtomicBool::new(false),
        stop: AtomicBool::new(false),
        capacity: capacity.max(1),
    });
    let shared = channel.clone();
    let owner = subscription.owner().to_string();
    let _ = std::thread::Builder::new().name(format!("wa-bus-{owner}")).spawn(move || {
        // The pump owns the `Subscription`: dropping it here is the unsubscribe, whether the guest
        // dropped the stream, the component stopped, or the bus revoked the owner.
        let mut subscription = subscription;
        loop {
            for event in subscription.drain(0) {
                shared.push(event);
            }
            if shared.stop.load(Ordering::Relaxed) || subscription.is_closed() {
                shared.closed.store(true, Ordering::Relaxed);
                shared.notify.notify();
                return;
            }
            std::thread::sleep(PUMP_TICK);
        }
    });
    channel
}

/// One guest's stream: the queue the pump fills, one event per item.
struct StreamProducer {
    channel: Arc<Channel>,
}

impl Drop for StreamProducer {
    fn drop(&mut self) {
        self.channel.stop.store(true, Ordering::Relaxed);
    }
}

impl<State: 'static> wasmtime::component::StreamProducer<State> for StreamProducer {
    type Item = GuestEvent;
    type Buffer = Option<GuestEvent>;

    fn poll_produce<'a>(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        _store: wasmtime::StoreContextMut<'a, State>,
        mut dst: wasmtime::component::Destination<'a, Self::Item, Self::Buffer>,
        finish: bool,
    ) -> std::task::Poll<wasmtime::Result<wasmtime::component::StreamResult>> {
        use std::task::Poll;
        loop {
            if let Some(event) = self.channel.pop() {
                dst.set_buffer(Some(to_guest(event)));
                return Poll::Ready(Ok(wasmtime::component::StreamResult::Completed));
            }
            if self.channel.closed.load(Ordering::Relaxed) {
                return Poll::Ready(Ok(wasmtime::component::StreamResult::Dropped));
            }
            if finish {
                return Poll::Ready(Ok(wasmtime::component::StreamResult::Cancelled));
            }
            if self.channel.notify.poll(cx).is_pending() {
                return Poll::Pending;
            }
        }
    }
}

fn to_guest(event: LibraryEvent) -> GuestEvent {
    GuestEvent {
        id: event.id.0,
        topic: event.topic.as_str().to_string(),
        ts_ms: event.ts_ms,
        source: event.source,
        schema: event.schema.name,
        schema_version: event.schema.version,
        trace: event.trace,
        payload: event.payload,
    }
}

/// One passage point for the component name, so both runners (`service_components` 0.1 and
/// `service_components_v2` 0.2) share the same host impls and cannot drift: the guest is attributed
/// and gated by the installed name, never by anything it says about itself.
pub(crate) trait BusCaller {
    fn component(&self) -> &str;
}

impl BusCaller for crate::service_components::State {
    fn component(&self) -> &str {
        &self.name
    }
}

impl BusCaller for crate::service_components_v2::State {
    fn component(&self) -> &str {
        &self.name
    }
}

/// The `wa:bus` host traits are generated in this crate, and they are implemented once per runner's
/// store state. A macro, not a blanket impl: bindgen generates its own blanket `impl Host for
/// &mut T`, so a blanket impl over every `T: BusCaller` would overlap with it - and a second
/// hand-written copy of the bodies per runner is exactly how the two contracts would drift.
macro_rules! bus_impls {
    ($state:ty) => {
        // The shared `types` interface has no functions, so its host trait is empty; it still has to
        // be implemented for the store state `add_to_linker` projects to.
        impl wa::bus::types::Host for $state {}
        impl wa::bus::publisher::Host for $state {}

        impl wa::bus::publisher::HostWithStore<$state> for $state {
            /// `publish` is `async` in the WIT, but the bus answers locally: the call completes in
            /// the poll it started in. A `block` subscriber that is full is the one case that could
            /// wait; the library reports it as a refusal instead of suspending, and the guest retries.
            async fn publish(
                accessor: &wasmtime::component::Accessor<$state, Self>,
                event: GuestEvent,
            ) -> Result<wa::bus::types::PublishReport, BusFault> {
                let component = accessor.with(|mut access| access.get().component().to_string());
                let mut call = crate::node_telemetry::HostCallGuard::start(&component, "bus.publish");
                let out = node().publish(&component, event).map(|report| wa::bus::types::PublishReport {
                    matched: report.matched,
                    delivered: report.delivered,
                    dropped: report.dropped,
                });
                call.outcome(&out);
                out
            }
        }

        impl wa::bus::subscriber::Host for $state {}

        impl wa::bus::subscriber::HostWithStore<$state> for $state {
            /// `subscribe` hands the guest a `stream<event>`. The pump thread owns the
            /// `wa_bus::Subscription`; the producer the runtime holds owns the stream's life, and
            /// dropping it is the unsubscribe.
            fn subscribe(
                mut access: wasmtime::component::Access<$state, Self>,
                pattern: String,
                options: SubscriptionOptions,
                replay: Option<u32>,
            ) -> wasmtime::Result<Result<wasmtime::component::StreamReader<GuestEvent>, BusFault>> {
                let component = access.data_mut().component().to_string();
                let mut call = crate::node_telemetry::HostCallGuard::start(&component, "bus.subscribe");
                let capacity = (options.capacity as usize).clamp(1, 4096);
                let subscribe = SubscribeOptions::new().with_capacity(capacity).with_policy(overflow(options.overflow));
                let subscription = match node().subscribe(&component, &pattern, subscribe, replay.map(|n| n as usize)) {
                    Ok(subscription) => subscription,
                    Err(fault) => {
                        call.outcome::<(), _>(&Err(&fault));
                        return Ok(Err(fault));
                    }
                };
                call.succeed();
                let channel = pump(subscription, capacity);
                let reader = wasmtime::component::StreamReader::new(
                    access.as_context_mut(),
                    StreamProducer { channel },
                )?;
                Ok(Ok(reader))
            }
        }
    };
}

bus_impls!(crate::service_components::State);
bus_impls!(crate::service_components_v2::State);

/// Bind `wa:bus` into a linker, next to the `wa:kernel` bindings of each runner, so a component
/// that imports `wa:bus` links or fails at instantiation - never at a missing host call later.
/// Two functions rather than one generic: `add_to_linker` wants `D = State` (the store's data
/// projection is the state itself), which names the concrete state type anyway.
pub(crate) fn link(linker: &mut wasmtime::component::Linker<crate::service_components::State>) -> wasmtime::Result<()> {
    EventBus::add_to_linker::<crate::service_components::State, crate::service_components::State>(linker, |s| s)
}

pub(crate) fn link_v2(linker: &mut wasmtime::component::Linker<crate::service_components_v2::State>) -> wasmtime::Result<()> {
    EventBus::add_to_linker::<crate::service_components_v2::State, crate::service_components_v2::State>(linker, |s| s)
}

#[cfg(test)]
mod tests;
