//! Offer/accept: one round trip to ask the best candidate, and a window after which this node does
//! the job itself.
//!
//! The rule the whole fabric hangs on: **an offer reserves nothing.** The accepting peer answers "I
//! can take it", then leases the job from the queue — and `wa-queue`'s lease is the only thing that
//! decides who runs it ("first lease wins"). So a peer that answers late, a peer that answers and
//! dies, and a local worker that started anyway cannot produce two runs of one job: at most one of
//! them holds the lease, and the queue refuses the other's settle (`docs/QUEUE.md`).
//!
//! The state machine ([`Router`]) is bounded in time and in attempts:
//!
//! * one **window** (default 200 ms, `WASM_AGENT_FABRIC_OFFER_MS`) for the whole placement, not per
//!   attempt — a refusal from the best candidate may fall through to the next one, but only inside
//!   the same window;
//! * when the window elapses, or nothing better than self was found, the job runs **here**, now. The
//!   local path is a plan, not an error path: `Plan::Local` never waits for anything.
//!
//! The wire records are strict JSON with a fixed key set ([`crate::wire`]): an unknown field, a wrong
//! version, an oversized id or a reply for a different offer is refused, never half-applied.

use std::collections::BTreeMap;

use serde_json::{json, Value};

use crate::placement::{Candidate, Decision, LocalReason, Plan, Request};
use crate::presence::{Capabilities, NodeId};
use crate::wire::{self, Refusal};
use crate::Config;

/// How long an offer waits for an accept. Short on purpose: a placement that costs a person 200 ms of
/// latency is already too expensive if the local path could have started immediately.
pub const DEFAULT_OFFER_WINDOW_MS: i64 = 200;

/// The longest offer window an operator may configure. Beyond this the fabric is not "near-instant".
pub const MAX_OFFER_WINDOW_MS: i64 = 10_000;

/// The longest offer id (the relay's idempotency id is the same shape).
pub const MAX_RID: usize = 96;

/// The longest refusal reason a peer may send back.
pub const MAX_REASON: usize = wire::MAX_REASON;

/// The most ranked candidates a router keeps for fall-through. A refusal storm must not grow a
/// per-job list without bound.
pub const MAX_FALLTHROUGH: usize = 4;

/// The longest job-kind word on an offer.
pub const MAX_KIND: usize = 32;

/// One offer: "will you take job `job` of kind `kind`, and answer before `deadline_ms`?"
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Offer {
    pub kind: String,
    pub job: u64,
    pub from: NodeId,
    pub to: NodeId,
    pub rid: String,
    /// Absolute, in the **sender's** clock: the window is the sender's to enforce, and the receiver
    /// only refuses an offer that arrives after it (a wrong clock can only cost a peer an offer).
    pub deadline_ms: i64,
    pub payload_bytes: u64,
    pub lease_ms: i64,
    pub needs: Capabilities,
}

impl Offer {
    pub fn to_json(&self) -> Value {
        json!({
            "v": wire::VERSION,
            "kind": self.kind,
            "job": self.job,
            "from": self.from.as_str(),
            "to": self.to.as_str(),
            "rid": self.rid,
            "deadline_ms": self.deadline_ms,
            "payload_bytes": self.payload_bytes,
            "lease_ms": self.lease_ms,
            "needs": self.needs.to_json(),
        })
    }

    pub fn encode(&self) -> Vec<u8> {
        self.to_json().to_string().into_bytes()
    }

    pub fn decode(bytes: &[u8]) -> Result<Offer, Refusal> {
        let value = wire::object(
            bytes,
            &["v", "kind", "job", "from", "to", "rid", "deadline_ms", "payload_bytes", "lease_ms", "needs"],
        )?;
        let kind = wire::bounded(&value, "kind", MAX_KIND)?;
        let from = NodeId::new(wire::bounded(&value, "from", crate::presence::MAX_NODE_ID)?)
            .ok_or(Refusal::Malformed("from"))?;
        let to = NodeId::new(wire::bounded(&value, "to", crate::presence::MAX_NODE_ID)?)
            .ok_or(Refusal::Malformed("to"))?;
        let rid = wire::bounded(&value, "rid", MAX_RID)?;
        let needs = Capabilities::from_json(value.get("needs").ok_or(Refusal::Malformed("needs"))?)
            .ok_or(Refusal::Malformed("needs"))?;
        Ok(Offer {
            kind,
            job: wire::unsigned(&value, "job")?,
            from,
            to,
            rid,
            deadline_ms: wire::signed(&value, "deadline_ms")?,
            payload_bytes: wire::unsigned(&value, "payload_bytes")?,
            lease_ms: wire::signed(&value, "lease_ms")?,
            needs,
        })
    }
}

/// The peer's yes. `lease_ms` is the lease it will take, so the sender can size its own window and
/// log a peer that asks for a shorter lease than the job needs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Accept {
    pub rid: String,
    pub node: NodeId,
    pub lease_ms: i64,
    pub at_ms: i64,
}

impl Accept {
    pub fn to_json(&self) -> Value {
        json!({
            "v": wire::VERSION,
            "accept": self.rid,
            "node": self.node.as_str(),
            "lease_ms": self.lease_ms,
            "at_ms": self.at_ms,
        })
    }

    pub fn encode(&self) -> Vec<u8> {
        self.to_json().to_string().into_bytes()
    }

    pub fn decode(bytes: &[u8]) -> Result<Accept, Refusal> {
        let value = wire::object(bytes, &["v", "accept", "node", "lease_ms", "at_ms"])?;
        Ok(Accept {
            rid: wire::bounded(&value, "accept", MAX_RID)?,
            node: NodeId::new(wire::bounded(&value, "node", crate::presence::MAX_NODE_ID)?)
                .ok_or(Refusal::Malformed("node"))?,
            lease_ms: wire::signed(&value, "lease_ms")?,
            at_ms: wire::signed(&value, "at_ms")?,
        })
    }
}

/// The peer's no, with one bounded word: `busy`, `incapable`, `late`, `wrong_target`, `fabric_off`,
/// `no_view`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refuse {
    pub rid: String,
    pub node: NodeId,
    pub reason: String,
}

impl Refuse {
    pub fn new(rid: impl Into<String>, node: &NodeId, reason: &str) -> Refuse {
        Refuse { rid: rid.into(), node: node.clone(), reason: wire::one_line(reason, MAX_REASON) }
    }

    pub fn to_json(&self) -> Value {
        json!({
            "v": wire::VERSION,
            "refuse": self.rid,
            "node": self.node.as_str(),
            "reason": self.reason,
        })
    }

    pub fn encode(&self) -> Vec<u8> {
        self.to_json().to_string().into_bytes()
    }

    pub fn decode(bytes: &[u8]) -> Result<Refuse, Refusal> {
        let value = wire::object(bytes, &["v", "refuse", "node", "reason"])?;
        Ok(Refuse {
            rid: wire::bounded(&value, "refuse", MAX_RID)?,
            node: NodeId::new(wire::bounded(&value, "node", crate::presence::MAX_NODE_ID)?)
                .ok_or(Refusal::Malformed("node"))?,
            reason: wire::bounded(&value, "reason", MAX_REASON)?,
        })
    }
}

/// What came back for one offer. `Unreachable` is "no answer at all" (the relay refused, the node is
/// gone): it is the same decision as a refusal — fall through or run locally — but a different counter,
/// because "nobody answers" and "everybody is busy" are different fleet problems.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Reply {
    Accept(Accept),
    Refuse(Refuse),
    Unreachable(String),
}

/// What the caller does next. `Offer` is a send, `Placed` is "hand the lease to `node`", `Local` is
/// "run it here, now".
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Step {
    Offer(Box<Offer>),
    Placed { node: NodeId, rtt_ms: i64 },
    Local { because: LocalReason },
}

impl Step {
    pub fn is_local(&self) -> bool {
        matches!(self, Step::Local { .. })
    }
}

/// One offer in flight.
#[derive(Clone, Debug)]
struct Pending {
    offer: Offer,
    /// Candidates after the one being offered, best first: the fall-through list.
    rest: Vec<Candidate>,
    sent_at_ms: i64,
}

/// The placement state machine: one pending offer per job, one window for the whole placement.
#[derive(Clone, Debug)]
pub struct Router {
    self_id: NodeId,
    window_ms: i64,
    pending: BTreeMap<u64, Pending>,
    seq: u64,
}

impl Router {
    /// `self_id` must be a valid node id; `config` supplies the window and the fall-through bound.
    pub fn new(self_id: NodeId, config: &Config) -> Router {
        Router {
            self_id,
            window_ms: config.offer_window_ms.clamp(1, MAX_OFFER_WINDOW_MS),
            pending: BTreeMap::new(),
            seq: 0,
        }
    }

    pub fn self_id(&self) -> &NodeId {
        &self.self_id
    }

    pub fn window_ms(&self) -> i64 {
        self.window_ms
    }

    /// How many offers are in flight right now (bounded by the number of concurrent jobs).
    pub fn in_flight(&self) -> usize {
        self.pending.len()
    }

    /// Offers in flight, for the admin view: job, peer, and when the window closes.
    pub fn pending(&self) -> impl Iterator<Item = (u64, &Offer, i64)> {
        self.pending.iter().map(|(job, pending)| (*job, &pending.offer, pending.offer.deadline_ms))
    }

    /// Turn a placement decision into the next step: an offer to the winner, or the local path.
    pub fn place(&mut self, decision: Decision, request: &Request, now_ms: i64) -> Step {
        let (to, window_ms) = match &decision.plan {
            Plan::Offer { to, window_ms } => (to.clone(), (*window_ms).clamp(1, MAX_OFFER_WINDOW_MS)),
            Plan::Local { because } => return Step::Local { because: *because },
        };
        let mut rest = decision.rest();
        rest.truncate(MAX_FALLTHROUGH);
        self.seq = self.seq.wrapping_add(1);
        let rid = format!("{}-{}", self.self_id.as_str(), self.seq);
        let offer = Offer {
            kind: request.kind.clone(),
            job: request.job,
            from: self.self_id.clone(),
            to,
            rid,
            deadline_ms: now_ms.saturating_add(window_ms),
            payload_bytes: request.payload_bytes,
            lease_ms: request.lease_ms,
            needs: request.needs.clone(),
        };
        self.pending.insert(request.job, Pending { offer: offer.clone(), rest, sent_at_ms: now_ms });
        Step::Offer(Box::new(offer))
    }

    /// Handle the answer to the offer in flight for `job`.
    ///
    /// A reply whose id does not match the offer in flight (a duplicate, a replay, an answer to a
    /// previous attempt) is ignored: `None`. An accept is honoured even if the window has just closed
    /// but this node has not fallen back yet — the queue's lease, not this state machine, is what
    /// makes two winners impossible.
    pub fn on_reply(&mut self, job: u64, reply: Reply, now_ms: i64) -> Option<Step> {
        let pending = self.pending.get(&job)?.clone();
        match reply {
            Reply::Accept(accept) => {
                if accept.rid != pending.offer.rid || accept.node != pending.offer.to {
                    return None;
                }
                self.pending.remove(&job);
                Some(Step::Placed {
                    node: accept.node,
                    rtt_ms: now_ms.saturating_sub(pending.sent_at_ms).max(0),
                })
            }
            Reply::Refuse(refuse) => {
                if refuse.rid != pending.offer.rid {
                    return None;
                }
                Some(self.fall_through(job, now_ms, LocalReason::AllRefused))
            }
            Reply::Unreachable(_) => Some(self.fall_through(job, now_ms, LocalReason::AllRefused)),
        }
    }

    /// The window elapsed: every job whose offer is past its deadline runs locally. Returns one step
    /// per expired offer, so the caller can start them all in one tick.
    pub fn tick(&mut self, now_ms: i64) -> Vec<(u64, Step)> {
        let expired: Vec<u64> = self
            .pending
            .iter()
            .filter(|(_, pending)| now_ms >= pending.offer.deadline_ms)
            .map(|(job, _)| *job)
            .collect();
        let mut steps = Vec::with_capacity(expired.len());
        for job in expired {
            steps.push((job, self.fall_through(job, now_ms, LocalReason::OfferWindowElapsed)));
        }
        steps
    }

    /// Forget a job without a step: the caller settled it some other way (its own lease, a cancel).
    pub fn forget(&mut self, job: u64) -> bool {
        self.pending.remove(&job).is_some()
    }

    /// Offer the next candidate inside the same window, or fall back locally. A next candidate that
    /// is self is the local path — no point offering to ourselves.
    fn fall_through(&mut self, job: u64, now_ms: i64, because: LocalReason) -> Step {
        let Some(mut pending) = self.pending.remove(&job) else {
            return Step::Local { because };
        };
        if let Some(next) = pending.rest.first().cloned() {
            pending.rest.remove(0);
            if next.is_self {
                // Falling through to self is the local path, and the reason it was reached is the
                // caller's (`all_refused` / `offer_window_elapsed`), not "self was best".
                return Step::Local { because };
            }
            if now_ms >= pending.offer.deadline_ms {
                return Step::Local { because };
            }
            self.seq = self.seq.wrapping_add(1);
            pending.offer.rid = format!("{}-{}", self.self_id.as_str(), self.seq);
            pending.offer.to = next.node;
            pending.sent_at_ms = now_ms;
            let offer = pending.offer.clone();
            self.pending.insert(job, pending);
            return Step::Offer(Box::new(offer));
        }
        Step::Local { because }
    }
}

/// The accepting side: should this node take an offer, and what does it answer?
///
/// The answer is an **admission check on the load right now**, not on the load the sender scored and
/// not a reservation: this node says yes only when its own current numbers are inside the safety gates
/// and it serves the capabilities the offer names. A yes that later loses the lease race is the queue
/// working as designed (the sender's window has closed by then, so the local path already ran it and
/// the queue picks one winner).
pub fn answer(
    offer: &Offer,
    caps: &Capabilities,
    load: &crate::presence::Load,
    self_id: &str,
    now_ms: i64,
    config: &Config,
) -> Result<Accept, Refuse> {
    let refuse = |reason: &str| Err(Refuse::new(offer.rid.clone(), &offer.to, reason));
    if offer.to.as_str() != self_id {
        return refuse("wrong_target");
    }
    if !config.enabled {
        return refuse("fabric_off");
    }
    if now_ms > offer.deadline_ms {
        return refuse("late");
    }
    if !caps.covers(&offer.needs) {
        return refuse("incapable");
    }
    if !crate::placement::within_gates(load, &config.knobs) {
        return refuse("busy");
    }
    Ok(Accept { rid: offer.rid.clone(), node: offer.to.clone(), lease_ms: offer.lease_ms.max(1), at_ms: now_ms })
}
