//! The queue in the host: `wa:queue` served over `rust/wa-queue`, from each component's own kv.
//!
//! The library is the semantics (`rust/wa-queue`, `docs/QUEUE.md`); this module is the node half:
//!
//! 1. **One `wa_queue::Queue` per component**, over that component's kv sub-namespace `q/`
//!    (`rust/wa-kv`), so a queue never shares a namespace with the component's own keys. It is
//!    created on first use and rebuilt from the same bytes on the next start: the library keeps no
//!    in-memory state, so a restart is a new `Queue` over the same store.
//! 2. **The grant is per interface and per namespace.** The manifest declares
//!    `{"queue": {"interfaces": ["producer","worker"], "namespaces": ["wa.stt"]}}`; a call to an
//!    interface the grant does not name is `refused`, and a queue name the namespaces do not cover is
//!    `refused` as well. A name is covered by an exact grant (`wa.stt`) or by a prefix grant
//!    (`wa.*`, the same shape as the bus). The `admin` interface is a separate grant on purpose: a
//!    worker that can requeue its own dead letters can retry forever.
//! 3. **Scope by queue, not only by namespace.** `heartbeat`/`done`/`fail`/`progress` name a job id
//!    and a queue; the library takes the id only, so this module loads the job and compares its
//!    `queue` with the granted namespaces *before* calling the library. Without that check a worker
//!    granted `wa.stt` could settle a job of `wa.post` (`docs/QUEUE.md`, item 6).
//! 4. **The sweeper.** A host thread runs `expire_stale`/`sweep` for every registered component and
//!    drains `next_alerts()`. Alerts are a *record*, not a side effect: each one is written to the
//!    service log and published on the bus topic `kernel.queue.alert` (schema `wa.queue.alert`), so
//!    a channel component or an operator tool delivers them through its own capability. Nothing here
//!    formats a message or sends it.
//! 5. **Nothing to flush on stop.** All state is already in the kv; `unregister` drops the
//!    in-process handle and the grants. A job leased by a stopped worker stays leased and is
//!    recovered by the lease rule on the next `take`/`sweep`, exactly as a crashed worker's would be.
//!
//! Deliberately not here: a blocking `take` (the library has no wake path per queue, and
//! `docs/QUEUE.md` lists it as an open question), and a live tail of `progress` — the stream serves
//! the chunks that exist when it is opened, which is what a producer that polls wants.

use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use wasmtime::AsContextMut as _;
use wa_queue::{AlertKind, Job, JobId, Policy, Queue, QueueStats, TakeOutcome};

wasmtime::component::bindgen!({
    world: "consumer",
    path: "../../wit/queue",
    // `producer.progress` is a synchronous call that hands the guest a `stream`, so the host needs
    // the store to create the transmit handle (`wa:kernel@0.2`'s `socket.messages` rule).
    imports: {
        "wa:queue/producer.progress": store | trappable,
    },
});

use wa::queue::types::{
    Alert as GuestAlert, AlertBatch as GuestAlertBatch, AlertKind as GuestAlertKind, Enqueued, Error as QueueFault,
    FailOutcome as GuestFailOutcome, Job as GuestJob, Lease as GuestLease, Request as GuestRequest,
    State as GuestState, Stats as GuestStats, Sweep as GuestSweep,
};
use wa::queue::worker::TakeOutcome as GuestTake;

/// How often the host sweeps the queues. A sweep is idempotent and cheap (one scan of the ready
/// index per queue), and the library's own safety net (`take` expires stale jobs) means this tick
/// only decides how *visible* an expiry or a timeout is, never whether it happens.
const SWEEP_EVERY: Duration = Duration::from_secs(15);

/// How many alert records `status` reads per component. Counts only; the sweeper drains the rest
/// through `next_alerts()`.
#[allow(dead_code)] // read by `status`, which no node surface calls yet (see the note on it)
const ALERT_SCAN_LIMIT: usize = 64;

/// One component's queue grant, as the manifest writes it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Grants {
    pub interfaces: Vec<String>,
    pub namespaces: Vec<String>,
}

impl Grants {
    /// Read `capabilities.queue`. Absent means "no queue": a component with no grant imports nothing
    /// and is refused every call. A malformed grant is an error the loader reports, never a silent
    /// empty grant.
    ///
    /// Two spellings of the same grant are accepted, because both have been written down and one of
    /// them silently granting nothing is a trap:
    ///
    /// * what the interface list says (`{"interfaces": ["worker"], "namespaces": ["whatsapp.outbox"]}`),
    ///   one namespace list for every interface named;
    /// * what reads like a sentence and needs no knowledge of the interface names
    ///   (`{"consume": ["whatsapp.outbox"], "produce": ["wa.stt"]}`), where `consume` is the `worker`
    ///   interface and `produce` the `producer` one. `admin` has no shorthand on purpose: a component
    ///   that can requeue its own dead letters can retry forever, so that grant is always spelled out.
    pub fn from_manifest(manifest: &Value) -> Result<Grants, String> {
        let Some(queue) = manifest.get("capabilities").and_then(|c| c.get("queue")) else {
            return Ok(Grants::default());
        };
        let object = queue.as_object().ok_or_else(|| "invalid_component_grant:queue".to_string())?;
        let mut interfaces: Vec<String> = Vec::new();
        let mut namespaces: Vec<String> = Vec::new();
        for item in object.get("interfaces").and_then(Value::as_array).cloned().unwrap_or_default() {
            let name = item.as_str().ok_or_else(|| "invalid_component_grant:queue.interfaces".to_string())?;
            if !matches!(name, "producer" | "worker" | "admin") {
                return Err(format!("invalid_component_grant:queue.interfaces:{name}"));
            }
            if !interfaces.iter().any(|seen| seen == name) {
                interfaces.push(name.to_string());
            }
        }
        let mut named = |key: &str| -> Result<Vec<String>, String> {
            // Absent is no names; present-but-not-a-list is a malformed grant, never "no names".
            let Some(value) = object.get(key) else { return Ok(Vec::new()) };
            value
                .as_array()
                .cloned()
                .ok_or_else(|| format!("invalid_component_grant:queue.{key}"))?
                .iter()
                .map(|item| {
                    item.as_str()
                        .filter(|name| !name.is_empty() && name.len() <= 64)
                        .map(str::to_string)
                        .ok_or_else(|| format!("invalid_component_grant:queue.{key}"))
                })
                .collect()
        };
        for name in named("namespaces")? {
            if !namespaces.contains(&name) {
                namespaces.push(name);
            }
        }
        for (key, interface) in [("consume", "worker"), ("produce", "producer")] {
            let queues = named(key)?;
            if queues.is_empty() {
                continue;
            }
            if !interfaces.iter().any(|seen| seen == interface) {
                interfaces.push(interface.to_string());
            }
            for name in queues {
                if !namespaces.contains(&name) {
                    namespaces.push(name);
                }
            }
        }
        Ok(Grants { interfaces, namespaces })
    }

    pub fn may_use(&self, interface: &str) -> bool {
        self.interfaces.iter().any(|name| name == interface)
    }

    /// Is `queue` inside the granted namespaces? Exact, or a `prefix.*` grant that covers one more
    /// segment - the same rule the bus uses for patterns, so the two capabilities read alike.
    pub fn may_queue(&self, queue: &str) -> bool {
        self.namespaces.iter().any(|granted| {
            granted == queue
                || granted == "*"
                || (granted.ends_with(".*") && queue.starts_with(&granted[..granted.len() - 1]))
        })
    }

    pub fn to_json(&self) -> Value {
        json!({"interfaces": self.interfaces, "namespaces": self.namespaces})
    }
}

/// The node's queues and the grants that gate them.
pub struct QueueHost {
    grants: Mutex<BTreeMap<String, Grants>>,
    /// Where the queue provider's namespaces live. The installed component directory in production;
    /// a test passes its own so it never touches the node's data.
    dir: std::path::PathBuf,
}

impl QueueHost {
    pub fn new(dir: std::path::PathBuf) -> QueueHost {
        QueueHost { grants: Mutex::new(BTreeMap::new()), dir }
    }

    /// Record a component's queue grant. The queue itself is created lazily on the first call.
    pub fn register(&self, component: &str, manifest: &Value) -> Result<Grants, String> {
        let grants = Grants::from_manifest(manifest)?;
        self.grants
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(component.to_string(), grants.clone());
        Ok(grants)
    }

    /// Forget a component: its grant and the in-process queue handle. The data stays in the kv, which
    /// is the point of the library - a stopped component's jobs are still takeable by the next one.
    pub fn unregister(&self, component: &str) {
        self.grants.lock().unwrap_or_else(|e| e.into_inner()).remove(component);
    }

    pub fn grants(&self, component: &str) -> Option<Grants> {
        self.grants.lock().unwrap_or_else(|e| e.into_inner()).get(component).cloned()
    }

    /// The queue of one component, built on demand. `q/` is the library's own sub-namespace inside
    /// the component's kv (`docs/QUEUE.md`, item 3: a component's raw keys must never overlap it).
    ///
    /// A new `Queue` per call, deliberately: the library keeps **no in-memory state** - every
    /// operation is a read and a write on the kv - so a handle is cheap and a restart is a new
    /// `Queue` over the same bytes. It also keeps `QueueHost` `Send + Sync` without a lock around a
    /// library that is not (`wa_queue::Kv`/`Clock` are not `Send`), and a lease is never trusted
    /// from memory: it is compared with the clock.
    pub fn queue(&self, component: &str) -> Queue {
        Queue::new(
            Arc::new(crate::state_host::sub_namespace(&self.dir, component, "q/")),
            Arc::new(wa_queue::SystemClock),
            // The library's defaults: no freshness bound and no timeout unless a job asks for one
            // (`Policy::default` in `rust/wa-queue`). A host-wide knob would be a guess about every
            // queue on the node; per-job and per-queue decisions belong to the producer's request.
            Policy::default(),
        )
    }

    /// Gate one call: the interface must be granted, and (when it names a queue) the queue must be
    /// inside the granted namespaces.
    pub fn gate(&self, component: &str, interface: &str, queue: Option<&str>) -> Result<(), QueueFault> {
        let Some(grants) = self.grants(component) else {
            return Err(QueueFault::Refused(format!("queue_not_granted:{component}")));
        };
        if !grants.may_use(interface) {
            return Err(QueueFault::Refused(format!("queue_interface_not_granted:{interface}")));
        }
        if let Some(queue) = queue {
            if !grants.may_queue(queue) {
                return Err(QueueFault::Refused(format!("queue_namespace_not_granted:{interface}")));
            }
        }
        Ok(())
    }

    /// Gate a call that names a *job*: the job's queue must be granted, which is the check the
    /// library cannot make for itself (`docs/QUEUE.md`, item 6).
    fn gate_job(&self, component: &str, interface: &str, id: JobId) -> Result<Job, QueueFault> {
        self.gate(component, interface, None)?;
        let job = self.queue(component).job(id).map_err(fault)?.ok_or(QueueFault::NotFound)?;
        if !self.grants(component).is_some_and(|g| g.may_queue(&job.queue)) {
            return Err(QueueFault::Refused(format!("queue_namespace_not_granted:{interface}")));
        }
        Ok(job)
    }

    /// One maintenance pass over every registered component: expired leases, stale jobs, timeout
    /// alerts, retention. Returns the number of components swept and the alert records drained.
    pub fn sweep_all(&self) -> (usize, usize) {
        let components: Vec<String> = self
            .grants
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .keys()
            .cloned()
            .collect();
        let mut swept = 0;
        let mut delivered = 0;
        for component in components {
            let queue = self.queue(&component);
            let _ = queue.sweep();
            // Alerts are drained even for a component whose admin interface is not granted: the
            // records exist because jobs failed, and the node - not the component - is who delivers
            // them (`docs/QUEUE.md`, "Alert delivery").
            while let Ok(Some(batch)) = queue.next_alerts() {
                for alert in &batch.items {
                    deliver_alert(&component, alert);
                    delivered += 1;
                }
                if batch.items.is_empty() {
                    break;
                }
            }
            swept += 1;
        }
        (swept, delivered)
    }

    /// Counts for `status`: per component, per granted queue, counts only. Never a payload, never a
    /// reason.
    #[allow(dead_code)] // asserted by the tests; the /health row is a UI change this job does not make
    pub fn status(&self) -> Value {
        let components: Vec<(String, Grants)> = self
            .grants
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .map(|(name, grants)| (name.clone(), grants.clone()))
            .collect();
        let mut out = Vec::new();
        for (component, grants) in components {
            let queue = self.queue(&component);
            let queues = queue.queues().unwrap_or_default();
            let mut rows = Vec::new();
            for name in queues {
                if !grants.may_queue(&name) {
                    continue;
                }
                if let Ok(stats) = queue.stats(&name) {
                    rows.push(stats_json(&name, &stats));
                }
            }
            out.push(json!({
                "component": component,
                "granted": grants.to_json(),
                "queues": rows,
                "alerts": queue.alerts(None, ALERT_SCAN_LIMIT).map(|alerts| alerts.len()).unwrap_or(0),
            }));
        }
        json!({"components": out})
    }

    #[allow(dead_code)] // the directory a test (and a future status tool) reports
    pub fn dir(&self) -> &std::path::Path {
        &self.dir
    }
}

/// One alert, written where a person and a component can both see it: the process log for the
/// operator, and the bus topic for anything that wants to act on it. The line carries a queue name,
/// a job id, a kind and the library's already-sanitized one-line reason - never a payload.
fn deliver_alert(component: &str, alert: &wa_queue::Alert) {
    let reason = alert.reason.replace(['\n', '\r'], " ");
    eprintln!(
        "queue-alert component={component} queue={} job={} kind={} reason={reason}",
        alert.queue,
        alert.job.0,
        alert.kind.as_str()
    );
    let payload = json!({
        "component": component,
        "queue": alert.queue,
        "job": alert.job.0,
        "kind": alert.kind.as_str(),
        "reason": reason,
        "at_ms": alert.at,
    });
    let _ = crate::bus_host::node().publish_node_fact(
        crate::bus_host::QUEUE_ALERT_TOPIC,
        "wa.queue.alert",
        payload.to_string().into_bytes(),
    );
}

// ---- the node singleton ---------------------------------------------------------------------------

pub fn node() -> &'static QueueHost {
    static NODE: OnceLock<QueueHost> = OnceLock::new();
    NODE.get_or_init(|| {
        let host = QueueHost::new(wa_host_support::paths::component_dir());
        // Retention for the alert topic: a component that starts after an alert happened still sees
        // it (the bus is a fact log, not a mailbox - this is a bounded tail, not a queue).
        let namespace = crate::state_host::sub_namespace(&host.dir, "kernel", "b/");
        host_retention(Arc::new(namespace));
        start_sweeper();
        host
    })
}

/// The bus retention namespace for the node's own topics, as an `Arc<dyn wa_bus::Kv>`.
fn host_retention(namespace: Arc<wa_kv::Namespaced<crate::state_host::HostStore>>) {
    let kv: Arc<dyn wa_bus::Kv> = namespace;
    let _ = crate::bus_host::node().enable_retention(crate::bus_host::QUEUE_ALERT_TOPIC, 64, kv);
}

fn start_sweeper() {
    let _ = std::thread::Builder::new().name("wa-queue-sweeper".into()).spawn(|| loop {
        std::thread::sleep(SWEEP_EVERY);
        let _ = node().sweep_all();
    });
}

// ---- WIT mapping -----------------------------------------------------------------------------------

fn state_name(state: wa_queue::JobState) -> GuestState {
    match state {
        wa_queue::JobState::Ready => GuestState::Ready,
        wa_queue::JobState::Leased => GuestState::Leased,
        wa_queue::JobState::Done => GuestState::Done,
        wa_queue::JobState::Dead => GuestState::Dead,
        wa_queue::JobState::Expired => GuestState::Expired,
    }
}

fn job_to_guest(job: Job) -> GuestJob {
    GuestJob {
        id: job.id.0,
        queue: job.queue,
        payload: job.payload,
        priority: job.priority,
        state: state_name(job.state),
        attempts: job.attempts,
        max_attempts: job.max_attempts,
        created_at_ms: job.created_at.max(0) as u64,
        not_before_ms: job.not_before.max(0) as u64,
        fresh_until_ms: job.fresh_until.map(|ms| ms.max(0) as u64),
        deadline_ms: job.deadline.map(|ms| ms.max(0) as u64),
        dedupe_key: job.dedupe_key,
        last_error: job.last_error,
    }
}

fn stats_json(queue: &str, stats: &QueueStats) -> Value {
    json!({
        "queue": queue,
        "ready": stats.ready,
        "retrying": stats.retrying,
        "leased": stats.leased,
        "done": stats.done,
        "dead": stats.dead,
        "expired": stats.expired,
        "oldest_ready_age_ms": stats.oldest_ready_age_ms.max(0),
        "progress_bytes": stats.progress_bytes,
    })
}

fn stats_to_guest(stats: &QueueStats) -> GuestStats {
    GuestStats {
        ready: stats.ready as u32,
        retrying: stats.retrying as u32,
        leased: stats.leased as u32,
        done: stats.done as u32,
        dead: stats.dead as u32,
        expired: stats.expired as u32,
        oldest_ready_age_ms: stats.oldest_ready_age_ms.max(0) as u64,
        progress_bytes: stats.progress_bytes,
    }
}

fn alert_kind(kind: AlertKind) -> GuestAlertKind {
    match kind {
        AlertKind::Expired => GuestAlertKind::Expired,
        AlertKind::TimedOut => GuestAlertKind::TimedOut,
        AlertKind::Dead => GuestAlertKind::Dead,
    }
}

/// The library's refusal in the guest's vocabulary. A storage failure is `failed` and never a
/// success; a full queue is `full` with its numbers so the producer can back off; everything else
/// keeps its own reason word.
fn fault(error: wa_queue::QueueError) -> QueueFault {
    use wa_queue::QueueError as E;
    match error {
        E::Kv(reason) => QueueFault::Failed(reason),
        E::Invalid(reason) => QueueFault::Invalid(reason),
        E::NotFound => QueueFault::NotFound,
        E::LeaseLost => QueueFault::LeaseLost,
        E::TooLarge(reason) => QueueFault::TooLarge(reason),
        E::ProgressFull => QueueFault::TooLarge("progress_limit_reached".into()),
        E::Full { queue, ready, limit } => QueueFault::Full((queue, ready as u32, limit as u32)),
        E::Corrupt(reason) => QueueFault::Failed(format!("corrupt:{reason}")),
    }
}

fn request_from_guest(request: GuestRequest) -> wa_queue::EnqueueRequest {
    let mut out = wa_queue::EnqueueRequest::new(request.queue, request.payload).priority(request.priority);
    if let Some(at) = request.not_before_ms {
        out = out.not_before(at as i64);
    }
    if let Some(ms) = request.fresh_for_ms {
        out = out.fresh_for(fresh_ms(ms));
    }
    if let Some(attempts) = request.max_attempts {
        out = out.max_attempts(attempts);
    }
    if let Some(key) = request.dedupe_key {
        out = out.dedupe(key);
    }
    if let Some(ms) = request.deadline_in_ms {
        out = out.deadline_in(ms.min(u64::from(u32::MAX)) as i64);
    }
    out
}

/// A WIT `u64` millisecond window as the library's `i64`. A window longer than `i64::MAX` is not a
/// policy, it is a typo, and it is clamped rather than wrapped into the past.
fn fresh_ms(ms: u64) -> i64 {
    ms.min(i64::MAX as u64) as i64
}

/// Progress chunks as the guest's `stream<list<u8>>`: the chunks that existed when the call was
/// made, oldest first, then the stream ends. A live tail would need a wake path per job, which the
/// library does not keep (`docs/QUEUE.md`, "Blocking take").
struct ChunksProducer {
    chunks: std::vec::IntoIter<Vec<u8>>,
}

impl<State: 'static> wasmtime::component::StreamProducer<State> for ChunksProducer {
    type Item = Vec<u8>;
    type Buffer = Option<Vec<u8>>;

    fn poll_produce<'a>(
        mut self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
        _store: wasmtime::StoreContextMut<'a, State>,
        mut dst: wasmtime::component::Destination<'a, Self::Item, Self::Buffer>,
        _finish: bool,
    ) -> std::task::Poll<wasmtime::Result<wasmtime::component::StreamResult>> {
        use std::task::Poll;
        match self.chunks.next() {
            Some(chunk) => {
                dst.set_buffer(Some(chunk));
                Poll::Ready(Ok(wasmtime::component::StreamResult::Completed))
            }
            None => Poll::Ready(Ok(wasmtime::component::StreamResult::Dropped)),
        }
    }
}

// ---- the host impls ---------------------------------------------------------------------------------

/// One passage point for the component name, shared by both runners (`service_components` 0.1 and
/// `service_components_v2` 0.2), so attribution and gating cannot drift between contracts.
pub(crate) trait QueueCaller {
    fn component(&self) -> &str;
}

impl QueueCaller for crate::service_components::State {
    fn component(&self) -> &str {
        &self.name
    }
}

impl QueueCaller for crate::service_components_v2::State {
    fn component(&self) -> &str {
        &self.name
    }
}

/// The `wa:queue` host traits, generated in this crate, implemented once per runner state. A macro
/// rather than a blanket impl: bindgen generates its own blanket `impl Host for &mut T`, so a blanket
/// impl over every `T: QueueCaller` would overlap with it.
macro_rules! queue_impls {
    ($state:ty) => {
        impl wa::queue::types::Host for $state {}

        impl wa::queue::producer::Host for $state {}

        impl wa::queue::producer::HostWithStore<$state> for $state {
            /// The job as stored, or `not-found`. No payload boundary is crossed that the caller did
            /// not already own: a producer may read back the job it enqueued.
            async fn get(
                accessor: &wasmtime::component::Accessor<$state, Self>,
                job_id: u64,
            ) -> Result<GuestJob, QueueFault> {
                let component = accessor.with(|mut access| access.get().component().to_string());
                let mut call = wa_governance::node_telemetry::HostCallGuard::start(&component, "queue.get");
                let out = node().gate_job(&component, "producer", JobId(job_id)).map(job_to_guest);
                call.outcome(&out);
                out
            }

            async fn enqueue(
                accessor: &wasmtime::component::Accessor<$state, Self>,
                request: GuestRequest,
            ) -> Result<Enqueued, QueueFault> {
                let component = accessor.with(|mut access| access.get().component().to_string());
                let mut call = wa_governance::node_telemetry::HostCallGuard::start(&component, "queue.enqueue");
                let queue_name = request.queue.clone();
                let out = (|| {
                    node().gate(&component, "producer", Some(&queue_name))?;
                    let outcome = node().queue(&component).enqueue(request_from_guest(request)).map_err(fault)?;
                    Ok(Enqueued { job: outcome.id.0, deduped: outcome.dedupe_hit })
                })();
                call.outcome(&out);
                out
            }

            /// The progress chunks that exist for `job` after `after`, as a stream of `list<u8>`.
            /// A snapshot, not a live tail: the library keeps no wake path per job, and a producer
            /// that polls `progress(job, after)` gets the same answer one call at a time.
            fn progress(
                mut access: wasmtime::component::Access<$state, Self>,
                job_id: u64,
                after: u64,
            ) -> wasmtime::Result<wasmtime::component::StreamReader<Vec<u8>>> {
                let component = access.data_mut().component().to_string();
                let chunks: Vec<Vec<u8>> = node()
                    .gate_job(&component, "producer", JobId(job_id))
                    .and_then(|_| node().queue(&component).progress_since(JobId(job_id), after, 256).map_err(fault))
                    .map(|entries| entries.into_iter().map(|entry| entry.bytes).collect())
                    .unwrap_or_default();
                let reader = wasmtime::component::StreamReader::new(
                    access.as_context_mut(),
                    ChunksProducer { chunks: chunks.into_iter() },
                )?;
                Ok(reader)
            }
        }

        impl wa::queue::worker::Host for $state {}

        impl wa::queue::worker::HostWithStore<$state> for $state {
            async fn take(
                accessor: &wasmtime::component::Accessor<$state, Self>,
                queue: String,
                worker: String,
                lease_ms: Option<u64>,
            ) -> Result<GuestTake, QueueFault> {
                let component = accessor.with(|mut access| access.get().component().to_string());
                let mut call = wa_governance::node_telemetry::HostCallGuard::start(&component, "queue.take");
                let out = (|| {
                    node().gate(&component, "worker", Some(&queue))?;
                    let lease_ms = lease_ms.map(|ms| fresh_ms(ms));
                    match node().queue(&component).take(&queue, &worker, lease_ms).map_err(fault)? {
                        TakeOutcome::Job(job) => {
                            let lease_until = job.lease_until.unwrap_or(job.updated_at).max(0) as u64;
                            Ok(GuestTake::Taken(GuestLease { job: job_to_guest(*job), lease_until_ms: lease_until }))
                        }
                        TakeOutcome::AtLimit { leased, .. } => Ok(GuestTake::Busy(leased as u32)),
                        TakeOutcome::Empty => Ok(GuestTake::Empty),
                    }
                })();
                call.outcome(&out);
                out
            }

            async fn heartbeat(
                accessor: &wasmtime::component::Accessor<$state, Self>,
                queue: String,
                job_id: u64,
                worker: String,
                extend_ms: Option<u64>,
            ) -> Result<u64, QueueFault> {
                let component = accessor.with(|mut access| access.get().component().to_string());
                let mut call = wa_governance::node_telemetry::HostCallGuard::start(&component, "queue.heartbeat");
                let out = (|| {
                    node().gate(&component, "worker", Some(&queue))?;
                    let job = node().gate_job(&component, "worker", JobId(job_id))?;
                    // The grant check above is by namespace; the queue named in the call must match
                    // the job's own queue, or a worker granted two queues could extend across them.
                    if job.queue != queue {
                        return Err(QueueFault::Refused("queue_job_mismatch".into()));
                    }
                    node().queue(&component)
                        .heartbeat(JobId(job_id), &worker, extend_ms.map(fresh_ms))
                        .map_err(fault)
                        .map(|until| until.max(0) as u64)
                })();
                call.outcome(&out);
                out
            }

            async fn done(
                accessor: &wasmtime::component::Accessor<$state, Self>,
                queue: String,
                job_id: u64,
                worker: String,
                output: Vec<u8>,
            ) -> Result<GuestJob, QueueFault> {
                let component = accessor.with(|mut access| access.get().component().to_string());
                let mut call = wa_governance::node_telemetry::HostCallGuard::start(&component, "queue.done");
                let out = (|| {
                    node().gate(&component, "worker", Some(&queue))?;
                    let job = node().gate_job(&component, "worker", JobId(job_id))?;
                    if job.queue != queue {
                        return Err(QueueFault::Refused("queue_job_mismatch".into()));
                    }
                    node().queue(&component).done_by(JobId(job_id), &worker, &output).map_err(fault).map(job_to_guest)
                })();
                call.outcome(&out);
                out
            }

            async fn fail(
                accessor: &wasmtime::component::Accessor<$state, Self>,
                queue: String,
                job_id: u64,
                worker: String,
                reason: String,
            ) -> Result<GuestFailOutcome, QueueFault> {
                let component = accessor.with(|mut access| access.get().component().to_string());
                let mut call = wa_governance::node_telemetry::HostCallGuard::start(&component, "queue.fail");
                let out = (|| {
                    node().gate(&component, "worker", Some(&queue))?;
                    let job = node().gate_job(&component, "worker", JobId(job_id))?;
                    if job.queue != queue {
                        return Err(QueueFault::Refused("queue_job_mismatch".into()));
                    }
                    let outcome = node().queue(&component).fail_by(JobId(job_id), &worker, &reason).map_err(fault)?;
                    Ok(GuestFailOutcome {
                        retry_at_ms: outcome.not_before.map(|ms| ms.max(0) as u64),
                        dead: outcome.dead,
                        attempts: outcome.attempts,
                    })
                })();
                call.outcome(&out);
                out
            }

            async fn progress(
                accessor: &wasmtime::component::Accessor<$state, Self>,
                queue: String,
                job_id: u64,
                chunk: Vec<u8>,
            ) -> Result<u64, QueueFault> {
                let component = accessor.with(|mut access| access.get().component().to_string());
                let mut call = wa_governance::node_telemetry::HostCallGuard::start(&component, "queue.progress");
                let out = (|| {
                    node().gate(&component, "worker", Some(&queue))?;
                    let job = node().gate_job(&component, "worker", JobId(job_id))?;
                    if job.queue != queue {
                        return Err(QueueFault::Refused("queue_job_mismatch".into()));
                    }
                    node().queue(&component).progress(JobId(job_id), &chunk).map_err(fault)
                })();
                call.outcome(&out);
                out
            }
        }

        impl wa::queue::admin::Host for $state {}

        impl wa::queue::admin::HostWithStore<$state> for $state {
            async fn stats(
                accessor: &wasmtime::component::Accessor<$state, Self>,
                queue: String,
            ) -> Result<GuestStats, QueueFault> {
                let component = accessor.with(|mut access| access.get().component().to_string());
                let mut call = wa_governance::node_telemetry::HostCallGuard::start(&component, "queue.stats");
                let out = (|| {
                    node().gate(&component, "admin", Some(&queue))?;
                    node().queue(&component).stats(&queue).map_err(fault).map(|stats| stats_to_guest(&stats))
                })();
                call.outcome(&out);
                out
            }

            async fn queues(accessor: &wasmtime::component::Accessor<$state, Self>) -> Result<Vec<String>, QueueFault> {
                let component = accessor.with(|mut access| access.get().component().to_string());
                let mut call = wa_governance::node_telemetry::HostCallGuard::start(&component, "queue.queues");
                let out = (|| {
                    node().gate(&component, "admin", None)?;
                    let grants = node().grants(&component).unwrap_or_default();
                    let mut queues = node().queue(&component).queues().map_err(fault)?;
                    queues.retain(|queue| grants.may_queue(queue));
                    Ok(queues)
                })();
                call.outcome(&out);
                out
            }

            async fn dead_letters(
                accessor: &wasmtime::component::Accessor<$state, Self>,
                queue: String,
                limit: u32,
            ) -> Result<Vec<GuestJob>, QueueFault> {
                let component = accessor.with(|mut access| access.get().component().to_string());
                let mut call = wa_governance::node_telemetry::HostCallGuard::start(&component, "queue.dead_letters");
                let out = (|| {
                    node().gate(&component, "admin", Some(&queue))?;
                    let limit = (limit as usize).clamp(1, 256);
                    node().queue(&component)
                        .dead_letters(&queue, limit)
                        .map_err(fault)
                        .map(|jobs| jobs.into_iter().map(job_to_guest).collect())
                })();
                call.outcome(&out);
                out
            }

            async fn requeue(
                accessor: &wasmtime::component::Accessor<$state, Self>,
                job_id: u64,
                refresh_freshness: bool,
            ) -> Result<GuestJob, QueueFault> {
                let component = accessor.with(|mut access| access.get().component().to_string());
                let mut call = wa_governance::node_telemetry::HostCallGuard::start(&component, "queue.requeue");
                let out = (|| {
                    let job = node().gate_job(&component, "admin", JobId(job_id))?;
                    let options = wa_queue::RequeueOptions {
                        refresh_fresh: refresh_freshness,
                        ..wa_queue::RequeueOptions::default()
                    };
                    let _ = job;
                    node().queue(&component).requeue_with(JobId(job_id), &options).map_err(fault).map(job_to_guest)
                })();
                call.outcome(&out);
                out
            }

            async fn next_alerts(
                accessor: &wasmtime::component::Accessor<$state, Self>,
            ) -> Result<Option<GuestAlertBatch>, QueueFault> {
                let component = accessor.with(|mut access| access.get().component().to_string());
                let mut call = wa_governance::node_telemetry::HostCallGuard::start(&component, "queue.next_alerts");
                let out = (|| {
                    node().gate(&component, "admin", None)?;
                    let grants = node().grants(&component).unwrap_or_default();
                    let batch = node().queue(&component).next_alerts().map_err(fault)?;
                    Ok(batch.map(|batch| GuestAlertBatch {
                        // An alert of a queue this caller may not see is not handed over; its record
                        // stays with the queue and the node delivers it (`sweep_all`).
                        items: batch
                            .items
                            .into_iter()
                            .filter(|alert| grants.may_queue(&alert.queue))
                            .map(|alert| GuestAlert {
                                job: alert.job.0,
                                queue: alert.queue,
                                kind: alert_kind(alert.kind),
                                reason: alert.reason,
                                at_ms: alert.at.max(0) as u64,
                            })
                            .collect(),
                        overflow: batch.overflow as u32,
                    }))
                })();
                call.outcome(&out);
                out
            }

            async fn sweep(accessor: &wasmtime::component::Accessor<$state, Self>) -> Result<GuestSweep, QueueFault> {
                let component = accessor.with(|mut access| access.get().component().to_string());
                let mut call = wa_governance::node_telemetry::HostCallGuard::start(&component, "queue.sweep");
                let out = (|| {
                    node().gate(&component, "admin", None)?;
                    let outcome = node().queue(&component).sweep().map_err(fault)?;
                    Ok(GuestSweep {
                        leases_recovered: outcome.leases_recovered as u32,
                        expired: outcome.expired as u32,
                        timed_out: outcome.timed_out as u32,
                        reaped: outcome.reaped as u32,
                    })
                })();
                call.outcome(&out);
                out
            }
        }
    };
}

queue_impls!(crate::service_components::State);
queue_impls!(crate::service_components_v2::State);

/// Bind `wa:queue` into a linker, beside the `wa:kernel` bindings of each runner.
pub(crate) fn link(linker: &mut wasmtime::component::Linker<crate::service_components::State>) -> wasmtime::Result<()> {
    Consumer::add_to_linker::<crate::service_components::State, crate::service_components::State>(linker, |s| s)
}

pub(crate) fn link_v2(linker: &mut wasmtime::component::Linker<crate::service_components_v2::State>) -> wasmtime::Result<()> {
    Consumer::add_to_linker::<crate::service_components_v2::State, crate::service_components_v2::State>(linker, |s| s)
}

#[cfg(test)]
mod tests;
