//! Three nodes in one process: the harness the fabric's tests drive.
//!
//! It is a simulation only in *transport*: each node has its own `wa-queue` over its own kv, its own
//! presence view, its own router and its own metrics, and a heartbeat, an offer, an accept and a
//! refusal are the real records ([`crate::offer`], [`crate::presence`]) encoded and decoded through
//! the real codec. What is simulated is the relay hop: a delivery is a function call, so the clock
//! moves by hand (`wa_queue::FixedClock`) and a test can say exactly when a lease lapsed.
//!
//! The three failures the brief names are all expressible here, and they are the tests:
//!
//! | failure | how the harness says it |
//! | --- | --- |
//! | a node that powers off | [`SimFabric::kill`] stops its heartbeats; after 3 missed beats it is stale |
//! | a node killed mid-job | the lease it holds stops being extended; [`SimFabric::recover`] requeues it |
//! | a peer whose answer never comes | [`SimNode::answer`] = false: the offer stays in flight until the window elapses |
//!
//! A node's `queue_depth` in its heartbeat is **read from its real queues** (`Queue::stats`), not set
//! by the test: the number placement scores is the number the queue holds.

use std::sync::Arc;

use wa_queue::{Clock, FixedClock, Job, JobId, JobState, MemoryKv, Policy, Queue};

use crate::lease::{queue_name, FabricLease, QUEUE_PREFIX};
use crate::metrics::FabricMetrics;
use crate::offer::{self, Reply, Router, Step};
use crate::placement::{self, Decision, LocalReason, Request};
use crate::presence::{Capabilities, Heartbeat, Load, NodeId, PresenceView};
use crate::Config;

/// One simulated node.
pub struct SimNode {
    pub id: NodeId,
    /// The capabilities it advertises.
    pub caps: Capabilities,
    /// CPU and memory pressure; the queue depth is read from the queues at beat time.
    pub load: Load,
    pub version: String,
    /// Live or powered off: a dead node publishes nothing and answers no offers.
    pub alive: bool,
    /// Answers offers. `false` is the wedged node: still beating, never answering.
    pub answer: bool,
    /// This node's instance generation, part of its lease worker id.
    pub generation: u64,
    pub view: PresenceView,
    pub queue: Queue,
    pub metrics: FabricMetrics,
    pub router: Router,
    /// When this node last published, so `tick` beats at the configured cadence.
    pub last_beat_ms: i64,
}

impl SimNode {
    /// The heartbeat this node publishes right now: real queue depth, its own clock.
    pub fn heartbeat(&self, now_ms: i64) -> Heartbeat {
        let depth = self
            .queue
            .queues()
            .map(|names| {
                names
                    .iter()
                    .filter(|name| name.starts_with(QUEUE_PREFIX))
                    .filter_map(|name| self.queue.stats(name).ok())
                    .map(|stats| stats.active())
                    .sum::<usize>()
            })
            .unwrap_or(0) as u32;
        let caps: Vec<String> = self.caps.iter().map(|capability| capability.as_str().to_string()).collect();
        Heartbeat::new(
            self.id.as_str(),
            caps,
            Load::new(depth, self.load.cpu_busy_pct, self.load.mem_used_pct),
            self.version.clone(),
            now_ms,
        )
    }
}

/// Where a job went, and how.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Placement {
    pub job: JobId,
    pub kind: String,
    /// The node that produced the job: its queue holds it, and its lease is the one that counts.
    pub producer: usize,
    /// The node that will run it.
    pub runner: usize,
    pub via: Via,
}

/// How the job got to its runner.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Via {
    /// A peer accepted the offer (after `offers` offers and `rtt_ms`).
    Accepted { node: String, offers: u32, rtt_ms: i64 },
    /// The local path: self was best, or nothing answered inside the window.
    Local { because: LocalReason },
}

/// One submission, and where it went. `placement` is `None` while an offer is still in flight (a
/// silent peer); the caller's next `tick` resolves it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Submitted {
    pub job: JobId,
    pub placement: Option<Placement>,
    pub decision: Decision,
}

/// A placement the router resolved on a tick: a window that elapsed, or a fall-through that ended
/// locally.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Timed {
    /// The node whose router resolved it (the producer).
    pub node: usize,
    pub job: u64,
    pub kind: String,
    pub step: Step,
}

/// The fabric, in one process.
pub struct SimFabric {
    pub clock: Arc<FixedClock>,
    pub config: Config,
    pub nodes: Vec<SimNode>,
    pub policy: Policy,
    /// Offers delivered (one per send that reached a node).
    pub deliveries: u64,
    pub offers: u64,
}

impl SimFabric {
    /// Build `ids.len()` nodes, all alive, all with the given capabilities, sharing one clock.
    pub fn new(config: Config, ids: &[&str], caps: &[&str]) -> SimFabric {
        let clock = Arc::new(FixedClock::new(1_000_000));
        let policy = Policy::default().with_fresh_ms(600_000);
        let capabilities = Capabilities::of(caps.iter().copied());
        let nodes = ids
            .iter()
            .map(|id| {
                let id = NodeId::new(*id).expect("valid sim node id");
                SimNode {
                    view: PresenceView::new(&config),
                    queue: Queue::new(Arc::new(MemoryKv::new()), clock.clone(), policy.clone()),
                    router: Router::new(id.clone(), &config),
                    metrics: FabricMetrics::new(),
                    id,
                    caps: capabilities.clone(),
                    load: Load::new(0, 5, 20),
                    version: "0.1.0".to_string(),
                    alive: true,
                    answer: true,
                    generation: 1,
                    last_beat_ms: 0,
                }
            })
            .collect();
        SimFabric { clock, config, nodes, policy, deliveries: 0, offers: 0 }
    }

    pub fn now(&self) -> i64 {
        self.clock.now_ms()
    }

    pub fn advance(&mut self, ms: i64) -> i64 {
        self.clock.advance(ms)
    }

    pub fn node(&self, index: usize) -> &SimNode {
        &self.nodes[index]
    }

    pub fn node_mut(&mut self, index: usize) -> &mut SimNode {
        &mut self.nodes[index]
    }

    /// Index of a node by id, for assertions that read better with names.
    pub fn index_of(&self, id: &str) -> Option<usize> {
        self.nodes.iter().position(|node| node.id.as_str() == id)
    }

    /// Set a node's CPU/memory pressure (its queue depth is always read from its queues).
    pub fn set_load(&mut self, index: usize, cpu_busy_pct: u8, mem_used_pct: u8) {
        self.nodes[index].load = Load::new(0, cpu_busy_pct, mem_used_pct);
    }

    /// Power a node off: it stops beating and answers nothing. Its lease, if it holds one, is not
    /// extended any more - which is the only thing that matters.
    pub fn kill(&mut self, index: usize) {
        self.nodes[index].alive = false;
        self.nodes[index].answer = false;
    }

    /// Power it back on with a new instance generation (its old leases are nobody's).
    pub fn revive(&mut self, index: usize) {
        self.nodes[index].alive = true;
        self.nodes[index].answer = true;
        self.nodes[index].generation += 1;
        self.nodes[index].last_beat_ms = 0;
    }

    /// Publish every live node's heartbeat to every node's view (and to its own: self is a candidate
    /// only when it knows its own load).
    pub fn beat(&mut self) {
        let now = self.now();
        let beats: Vec<Heartbeat> = self.nodes.iter().filter(|node| node.alive).map(|node| node.heartbeat(now)).collect();
        for node in &mut self.nodes {
            for beat in &beats {
                node.view.observe(beat.clone(), now);
            }
        }
        for node in &mut self.nodes {
            if node.alive {
                node.last_beat_ms = now;
            }
        }
    }

    /// One housekeeping tick: beat when due, prune the views, and resolve every offer whose window
    /// elapsed. The caller decides what to do with each resolved placement.
    pub fn tick(&mut self) -> Vec<Timed> {
        let now = self.now();
        if self.nodes.iter().any(|node| node.alive && now - node.last_beat_ms >= self.config.heartbeat_ms) {
            self.beat();
        }
        let mut timed = Vec::new();
        for index in 0..self.nodes.len() {
            self.nodes[index].view.prune(now);
            let kinds: std::collections::BTreeMap<u64, String> = self.nodes[index]
                .router
                .pending()
                .map(|(job, offer, _)| (job, offer.kind.clone()))
                .collect();
            for (job, step) in self.nodes[index].router.tick(now) {
                let kind = kinds.get(&job).cloned().unwrap_or_default();
                timed.push(Timed { node: index, job, kind, step });
            }
        }
        timed
    }

    /// Enqueue one job on `producer`'s fabric queue and place it.
    pub fn submit(&mut self, producer: usize, kind: &str, payload: &[u8]) -> Option<Submitted> {
        let queue = queue_name(kind);
        let enqueued = self.nodes[producer]
            .queue
            .enqueue(wa_queue::EnqueueRequest::new(queue.clone(), payload.to_vec()))
            .ok()?;
        self.place(producer, kind, enqueued.id, payload.len() as u64)
    }

    /// Place a job that is already in the producer's queue (a requeued job, a second attempt).
    pub fn place_existing(&mut self, producer: usize, kind: &str, job: JobId, payload_bytes: u64) -> Option<Submitted> {
        self.place(producer, kind, job, payload_bytes)
    }

    /// Resolve a [`Timed`] into a placement, recording the counters the admin view shows.
    pub fn resolve(&mut self, timed: Timed) -> Option<Placement> {
        let Step::Local { because } = timed.step else { return None };
        if because == LocalReason::OfferWindowElapsed {
            self.nodes[timed.node].metrics.timed_out(timed.job);
        }
        self.nodes[timed.node].metrics.local_fallback(timed.job, because);
        Some(Placement {
            job: JobId(timed.job),
            kind: timed.kind,
            producer: timed.node,
            runner: timed.node,
            via: Via::Local { because },
        })
    }

    /// Take the lease for a placement. The lease is always the **producer's** queue's lease, whoever
    /// runs the job - that is what makes "first lease wins" true across nodes.
    pub fn begin(&mut self, placement: &Placement) -> Result<FabricLease, String> {
        let now = self.now();
        let runner = &self.nodes[placement.runner];
        let lease_ms = 5_000;
        let queue = queue_name(&placement.kind);
        let lease = FabricLease::take(
            &self.nodes[placement.producer].queue,
            &queue,
            &runner.id,
            runner.generation,
            lease_ms,
            now,
        )
        .map_err(|error| error.as_str().to_string())?;
        lease.ok_or_else(|| "nothing_due".to_string())
    }

    /// Settle a lease with its result. A lease that lapsed and was taken by another node is refused:
    /// `lost_settles` counts it and the queue keeps the single result it already has.
    pub fn settle(&mut self, producer: usize, lease: &FabricLease, result: &[u8]) -> Result<(), String> {
        match lease.done(&self.nodes[producer].queue, result) {
            Ok(()) => {
                self.nodes[producer].metrics.settled();
                Ok(())
            }
            Err(error) => {
                self.nodes[producer].metrics.settle_lost();
                Err(error.as_str().to_string())
            }
        }
    }

    /// Heartbeat a lease (what a running job does every few seconds).
    pub fn heartbeat(&mut self, producer: usize, lease: &mut FabricLease) -> Result<i64, String> {
        lease.heartbeat(&self.nodes[producer].queue).map_err(|error| error.as_str().to_string())
    }

    /// Recover lapsed leases of one fabric queue, exactly as the producer's sweep does. Returns how
    /// many jobs went back to `Ready`.
    pub fn recover(&mut self, producer: usize, kind: &str) -> usize {
        let _ = kind;
        let outcome = self.nodes[producer].queue.sweep();
        let recovered = outcome.map(|outcome| outcome.leases_recovered).unwrap_or(0);
        for _ in 0..recovered {
            self.nodes[producer].metrics.lease_expired();
        }
        recovered
    }

    /// The job as the producer's queue holds it.
    pub fn job(&self, producer: usize, job: JobId) -> Option<Job> {
        self.nodes[producer].queue.job(job).ok().flatten()
    }

    /// Every leased job on a producer's fabric queue (the admin view's `leases`).
    pub fn outstanding(&self, producer: usize, kind: &str) -> crate::lease::Outstanding {
        crate::lease::Outstanding::read(&self.nodes[producer].queue, &queue_name(kind), self.now(), 32)
    }

    /// The admin view for one node.
    pub fn admin(&self, index: usize, kind: &str) -> serde_json::Value {
        let node = &self.nodes[index];
        crate::admin::view(&crate::admin::FabricView {
            self_id: node.id.as_str(),
            config: &self.config,
            presence: &node.view,
            metrics: &node.metrics,
            now_ms: self.now(),
            leases: &[self.outstanding(index, kind)],
            in_flight_offers: node.router.in_flight(),
            recent: 16,
        })
    }

    /// Enqueue a filler job directly on a node's own queue, so its published `queue_depth` is real
    /// ("make this node busy" without lying about its load).
    pub fn enqueue_filler(&mut self, index: usize, kind: &str, count: usize) {
        for n in 0..count {
            let _ = self.nodes[index]
                .queue
                .enqueue(wa_queue::EnqueueRequest::new(queue_name(kind), format!("filler-{n}").into_bytes()));
        }
    }

    /// How many jobs of one queue are in each state (assertions read this).
    pub fn stats(&self, index: usize, kind: &str) -> wa_queue::QueueStats {
        self.nodes[index].queue.stats(&queue_name(kind)).unwrap_or_default()
    }

    /// Is a job settled, and with what?
    pub fn result(&self, producer: usize, job: JobId) -> Option<(JobState, Option<Vec<u8>>)> {
        self.job(producer, job).map(|job| (job.state, job.result))
    }

    fn place(&mut self, producer: usize, kind: &str, job: JobId, payload_bytes: u64) -> Option<Submitted> {
        let now = self.now();
        let request = Request::new(kind, job.0, payload_bytes).affinity(self.nodes[producer].id.as_str().to_string());
        let decision = placement::choose(
            &self.nodes[producer].view,
            &request,
            self.nodes[producer].id.as_str(),
            now,
            &self.config,
            &self.nodes[producer].metrics,
        );
        self.nodes[producer].metrics.decided(now, &request, &decision);
        let mut step = self.nodes[producer].router.place(decision.clone(), &request, now);
        let mut offers = 0u32;
        // Bounded: a fall-through list is capped by `MAX_FALLTHROUGH`, so this loop cannot spin.
        for _ in 0..(crate::offer::MAX_FALLTHROUGH + 2) {
            match step {
                Step::Local { because } => {
                    if offers > 0 {
                        self.nodes[producer].metrics.local_fallback(job.0, because);
                    }
                    let placement = Placement {
                        job,
                        kind: kind.to_string(),
                        producer,
                        runner: producer,
                        via: Via::Local { because },
                    };
                    return Some(Submitted { job, placement: Some(placement), decision });
                }
                Step::Placed { node, rtt_ms } => {
                    let runner = self.index_of(node.as_str())?;
                    self.nodes[producer].metrics.accepted(now, job.0, node.as_str(), rtt_ms);
                    let placement = Placement {
                        job,
                        kind: kind.to_string(),
                        producer,
                        runner,
                        via: Via::Accepted { node: node.as_str().to_string(), offers, rtt_ms },
                    };
                    return Some(Submitted { job, placement: Some(placement), decision });
                }
                Step::Offer(offer) => {
                    offers += 1;
                    self.offers += 1;
                    self.nodes[producer].metrics.offer_sent(&offer);
                    let Some(target) = self.index_of(offer.to.as_str()) else {
                        let reason = "unknown_node".to_string();
                        self.nodes[producer].metrics.unreachable(job.0, &reason);
                        step = self.nodes[producer].router.on_reply(job.0, Reply::Unreachable(reason), now)?;
                        continue;
                    };
                    let target_node = &self.nodes[target];
                    if !target_node.alive || !target_node.answer {
                        // No answer: the offer stays in flight. The window decides, not this call.
                        return Some(Submitted { job, placement: None, decision });
                    }
                    let now = self.now();
                    let self_id = self.nodes[target].id.as_str().to_string();
                    // The peer answers on its load **now**, not on the load the producer scored.
                    let beat = self.nodes[target].heartbeat(now);
                    match offer::answer(&offer, &beat.caps, &beat.load, &self_id, now, &self.config) {
                        Ok(accept) => {
                            self.deliveries += 1;
                            step = self.nodes[producer].router.on_reply(job.0, Reply::Accept(accept), now)?;
                        }
                        Err(refuse) => {
                            self.deliveries += 1;
                            self.nodes[producer].metrics.refused(job.0, &refuse.reason);
                            step = self.nodes[producer].router.on_reply(job.0, Reply::Refuse(refuse), now)?;
                        }
                    }
                }
            }
        }
        None
    }
}
