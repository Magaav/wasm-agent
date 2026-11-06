//! The direct transport, caller side: authorize, then try addresses cheapest first, then say so.
//!
//! A call goes out as one signed `POST /mesh/call` to each address in turn — LAN before public, the
//! roster's order inside a class, then anything the peer cache learned. The target's answer is
//! believed only when it is signed by the key the roster has for it. Two outcomes must never be
//! confused by the caller above:
//!
//! * **a verdict** (`Denied`, `Refused`) — somebody decided; falling back to the relay would ask a
//!   different, older authority and could launder the refusal away;
//! * **a transport failure** (`Unreachable`) — nobody decided; that is the only case in which the
//!   caller's existing direct/relay path should run, and the outcome says so (`fallback: relay`).
use crate::audit::{Event, Sink};
use crate::cache::PeerCache;
use crate::hierarchy::{authorize, Verdict, Verb};
use crate::http;
use crate::identity::Identity;
use crate::policy::MeshPolicy;
use crate::roster::{Roster, RosterNode};
use crate::wire::{self, MeshCall, MeshReply};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// The ordinary `/node/call` request the caller also built: carried opaquely so the target can hand
/// it to its own node path, with the headers the caller signed it with.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Inner {
    pub body: String,
    pub headers: Vec<(String, String)>,
}

#[derive(Debug, Clone)]
pub struct ClientConfig {
    pub connect_timeout: Duration,
    pub io_timeout: Duration,
    pub max_body: usize,
}

impl Default for ClientConfig {
    fn default() -> Self {
        ClientConfig {
            connect_timeout: Duration::from_secs(3),
            io_timeout: Duration::from_secs(60),
            max_body: http::MAX_BODY,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attempt {
    pub address: String,
    pub class: &'static str,
    pub status: Option<u16>,
    pub error: String,
}

impl Attempt {
    fn to_json(&self) -> Value {
        json!({"address": self.address, "class": self.class, "status": self.status, "error": self.error})
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// The target ran the call and answered with a signed reply.
    Ok {
        node: RosterNode,
        verdict: Verdict,
        verb: Verb,
        address: String,
        class: &'static str,
        status: u16,
        body: String,
    },
    /// Refused here, before any network call: the caller's own hierarchy or a deny grant.
    Denied { node: RosterNode, verdict: Verdict, verb: Verb },
    /// The target refused, or answered something the caller cannot believe.
    Refused { node: RosterNode, code: String, verified: bool, status: u16, detail: String },
    /// Nobody answered. This is the only outcome that permits the caller's fallback path.
    Unreachable { node: RosterNode, attempts: Vec<Attempt>, reason: String },
    /// No such node in the roster.
    Unknown { selector: String },
    /// The mesh cannot decide at all (no roster, no key, caller not in the roster). Fail closed: a
    /// caller that cannot authorize must not call.
    Unavailable { reason: String, detail: String },
}

impl Outcome {
    /// The JSON contract `host.mesh_call` answers with. One place builds it, so the Lua side, the
    /// tests and `docs/MESH.md` cannot disagree.
    pub fn to_json(&self) -> Value {
        match self {
            Outcome::Ok { node, verdict, verb, address, class, status, body } => json!({
                "ok": true,
                "transport": "mesh",
                "node": node.name,
                "node_id": node.node_id,
                "level": node.level,
                "address": address,
                "addr_class": class,
                "verb": verb.as_str(),
                "decision": verdict.decision(),
                "reason": verdict.reason,
                "status": status,
                "body": body,
                "verified": true,
            }),
            Outcome::Denied { node, verdict, verb } => json!({
                "ok": false,
                "error": "mesh_denied",
                "reason": verdict.reason,
                "detail": verdict.detail,
                "node": node.name,
                "node_id": node.node_id,
                "level": node.level,
                "verb": verb.as_str(),
                "verified": true,
                "fallback": null,
            }),
            Outcome::Refused { node, code, verified, status, detail } => json!({
                "ok": false,
                "error": "mesh_refused",
                "code": code,
                "detail": detail,
                "node": node.name,
                "node_id": node.node_id,
                "status": status,
                "verified": verified,
                "fallback": null,
            }),
            Outcome::Unreachable { node, attempts, reason } => json!({
                "ok": false,
                "error": "mesh_unreachable",
                "reason": reason,
                "node": node.name,
                "node_id": node.node_id,
                "attempts": attempts.iter().map(Attempt::to_json).collect::<Vec<_>>(),
                "fallback": "relay",
            }),
            Outcome::Unknown { selector } => json!({
                "ok": false, "error": "mesh_unknown_node", "node": selector, "fallback": null,
            }),
            Outcome::Unavailable { reason, detail } => json!({
                "ok": false, "error": "mesh_unavailable", "reason": reason, "detail": detail,
                "fallback": null,
            }),
        }
    }
}

static REQUEST_COUNTER: AtomicU64 = AtomicU64::new(0);

fn next_request_id(now_ms: u64) -> String {
    let counter = REQUEST_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{now_ms:x}-{:x}-{counter:x}", std::process::id())
}

pub struct Client<'a> {
    pub identity: &'a Identity,
    pub roster: &'a Roster,
    pub policy: &'a MeshPolicy,
    pub cache: &'a mut PeerCache,
    pub audit: &'a dyn Sink,
    pub config: ClientConfig,
}

impl<'a> Client<'a> {
    pub fn call(&mut self, selector: &str, capability: &str, args: Value, inner: Inner) -> Outcome {
        let Some(target) = self.roster.node(selector).cloned() else {
            return Outcome::Unknown { selector: selector.to_string() };
        };
        let Some(caller) = self.roster.node(&self.identity.node_id).cloned() else {
            return Outcome::Unavailable {
                reason: "self_not_in_roster".into(),
                detail: format!("this node ({}…) is not in the fleet roster", crate::audit::short(&self.identity.node_id)),
            };
        };
        let verb = Verb::from_capability(capability);
        let now_s = wire::now_seconds();
        let verdict = authorize(self.policy, &caller, &target, verb, now_s);
        if !verdict.is_allow() {
            Event::new("call", &caller.node_id, &target.node_id)
                .levels(Some(caller.level), Some(target.level))
                .verb(verb.as_str())
                .verdict(verdict.decision(), verdict.reason)
                .outcome(false, None, 0, 0)
                .emit(self.audit);
            return Outcome::Denied { node: target, verdict, verb };
        }

        let addresses = self.cache.addresses(&target);
        if addresses.is_empty() {
            return Outcome::Unreachable {
                node: target,
                attempts: Vec::new(),
                reason: "no_address".into(),
            };
        }

        let mut attempts: Vec<Attempt> = Vec::new();
        let mut attempt_index = 0u32;
        for address in addresses {
            attempt_index += 1;
            let class = RosterNode::address_class(&address);
            let started = Instant::now();
            let now_ms = wire::now_millis();
            let call = MeshCall {
                schema: wire::SCHEMA,
                request_id: next_request_id(now_ms),
                from_node_id: caller.node_id.clone(),
                to_node_id: target.node_id.clone(),
                capability: capability.to_string(),
                args: args.clone(),
                inner_body: inner.body.clone(),
                inner_headers: inner.headers.clone(),
            };
            let body = call.encode();
            let ts = wire::now_seconds();
            let signature = self.identity.sign(&MeshCall::call_message(&caller.node_id, ts, &body));
            let headers = vec![
                ("x-wa-mesh".to_string(), "1".to_string()),
                ("content-type".to_string(), "application/json".to_string()),
                ("x-wa-node".to_string(), caller.node_id.clone()),
                ("x-wa-pub".to_string(), self.identity.public_key.clone()),
                ("x-wa-ts".to_string(), ts.to_string()),
                ("x-wa-sig".to_string(), signature),
            ];
            let response = http::request(
                &address,
                "POST",
                "/mesh/call",
                &headers,
                body.as_bytes(),
                self.config.connect_timeout,
                self.config.io_timeout,
                self.config.max_body,
            );
            let elapsed = started.elapsed().as_millis() as u64;
            let transport = format!("direct:{class}");
            match response {
                Err(error) => {
                    self.cache.record_failure(&target.node_id, &error);
                    Event::new("call", &caller.node_id, &target.node_id)
                        .levels(Some(caller.level), Some(target.level))
                        .verb(verb.as_str())
                        .verdict("deny", &format!("unreachable:{error}"))
                        .transport(&transport, class)
                        .outcome(false, None, elapsed, attempt_index)
                        .emit(self.audit);
                    attempts.push(Attempt { address, class, status: None, error });
                }
                Ok(response) => {
                    let status = response.status;
                    let reply_text = response.body_text();
                    let reply_signature = response.header("x-wa-sig").map(str::to_string);
                    let reply_ts = response.header("x-wa-ts").and_then(|value| value.parse::<u64>().ok());
                    let verified = match (reply_signature, reply_ts) {
                        (Some(signature), Some(ts)) => crate::identity::verify(
                            &target.public_key,
                            &MeshReply::reply_message(&target.node_id, &caller.node_id, ts, &reply_text),
                            &signature,
                        ),
                        _ => false,
                    };
                    if status == 200 && verified {
                        match MeshReply::parse(&reply_text) {
                            Ok(reply) if reply.request_id == call.request_id => {
                                if reply.ok {
                                    let inner_status = reply.status.unwrap_or(200);
                                    self.cache.record_success(&target.node_id, &address, wire::now_millis());
                                    Event::new("call", &caller.node_id, &target.node_id)
                                        .levels(Some(caller.level), Some(target.level))
                                        .verb(verb.as_str())
                                        .verdict("allow", verdict.reason)
                                        .transport(&transport, class)
                                        .outcome(true, Some(inner_status), elapsed, attempt_index)
                                        .emit(self.audit);
                                    return Outcome::Ok {
                                        node: target,
                                        verdict,
                                        verb,
                                        address,
                                        class,
                                        status: inner_status,
                                        body: reply.body.unwrap_or_default(),
                                    };
                                }
                                let code = reply.error.unwrap_or_else(|| "mesh_refused".into());
                                let detail = reply.detail.or(reply.reason).unwrap_or_default();
                                Event::new("call", &caller.node_id, &target.node_id)
                                    .levels(Some(caller.level), Some(target.level))
                                    .verb(verb.as_str())
                                    .verdict("deny", &code)
                                    .transport(&transport, class)
                                    .outcome(false, Some(status), elapsed, attempt_index)
                                    .emit(self.audit);
                                return Outcome::Refused {
                                    node: target,
                                    code,
                                    verified: true,
                                    status,
                                    detail,
                                };
                            }
                            _ => {}
                        }
                    }
                    // A refusal *before* authentication is unsigned, so only its allow-listed code
                    // is believed, and only as a diagnosis.
                    let code = wire::pre_auth_code(&reply_text).unwrap_or("unverified_reply");
                    Event::new("call", &caller.node_id, &target.node_id)
                        .levels(Some(caller.level), Some(target.level))
                        .verb(verb.as_str())
                        .verdict("deny", code)
                        .transport(&transport, class)
                        .outcome(false, Some(status), elapsed, attempt_index)
                        .emit(self.audit);
                    if code == "not_found" || code == "not_mesh" || code == "too_large" {
                        // The address is not a mesh listener (or the body was refused as a whole):
                        // another address for the same node may still be one.
                        attempts.push(Attempt {
                            address,
                            class,
                            status: Some(status),
                            error: code.to_string(),
                        });
                        continue;
                    }
                    return Outcome::Refused {
                        node: target,
                        code: code.to_string(),
                        verified: false,
                        status,
                        detail: String::new(),
                    };
                }
            }
        }
        let reason = attempts
            .last()
            .map(|attempt| attempt.error.clone())
            .unwrap_or_else(|| "unreachable".into());
        self.cache.record_failure(&target.node_id, &reason);
        Outcome::Unreachable { node: target, attempts, reason }
    }
}
