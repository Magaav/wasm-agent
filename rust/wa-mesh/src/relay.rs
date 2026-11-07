//! The relay, as transport only.
//!
//! Most nodes have no public address, so the mesh's direct path cannot reach them. The relay already
//! exists for exactly that, and this module puts a **mesh call** — the same signed envelope, the same
//! headers, byte for byte — through it. Nothing here decides anything: the relay forwards bytes, the
//! *target* decides with its roster ([`crate::admission`]), and the caller believes an answer only
//! when it is signed by the key the roster has for that node id.
//!
//! One thing the relay makes different: it hands on a status and a body and **drops headers**. The
//! direct listener puts its reply signature in `x-wa-sig`, so a relayed answer carries the same
//! signature *inside* its body ([`RelayAnswer`]). The signed message is unchanged
//! (`mesh-reply-v1|<target>|<caller>|<ts>|<sha256(reply)>`), so a relayed reply and a direct one are
//! the same statement about the same bytes — only the carrier differs.
//!
//! Relay requests are signed the way the rendezvous requires (`relay-send|<node_id>|<ts>`); the
//! `body` of the relay POST is the envelope, which the relay never looks inside.
use crate::identity::Identity;
use crate::wire::{self, MeshReply};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::Duration;

pub const RELAY_ANSWER_SCHEMA: u32 = 1;

/// A reply that travelled without headers: the same [`MeshReply`] bytes plus the signature the direct
/// listener would have put in a header.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RelayAnswer {
    pub schema: u32,
    /// Unix seconds, inside the signature: a captured answer cannot be presented as a fresh one.
    pub ts: u64,
    pub from_node_id: String,
    /// The `MeshReply`, verbatim: the bytes that were signed, so a re-encoding cannot change what was
    /// verified.
    pub reply: String,
    pub signature: String,
}

impl RelayAnswer {
    pub fn seal(
        identity: &Identity,
        target_node_id: &str,
        caller_node_id: &str,
        reply: &MeshReply,
    ) -> RelayAnswer {
        let reply = reply.encode();
        let ts = wire::now_seconds();
        RelayAnswer {
            schema: RELAY_ANSWER_SCHEMA,
            ts,
            from_node_id: target_node_id.to_string(),
            signature: identity
                .sign(&MeshReply::reply_message(target_node_id, caller_node_id, ts, &reply)),
            reply,
        }
    }

    pub fn encode(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{}".to_string())
    }

    /// Parse and verify against the roster's key for the target, then hand back the reply. Anything
    /// unsigned, stale or meant for another pair of nodes is `Err` — an unsigned answer is never a
    /// result, on any path.
    pub fn open(
        text: &str,
        target_node_id: &str,
        target_public_key: &str,
        caller_node_id: &str,
        now_s: u64,
    ) -> Result<MeshReply, String> {
        let answer: RelayAnswer =
            serde_json::from_str(text).map_err(|error| format!("relay_answer_unreadable:{error}"))?;
        if answer.schema != RELAY_ANSWER_SCHEMA {
            return Err(format!("relay_answer_schema:{}", answer.schema));
        }
        if answer.from_node_id != target_node_id {
            return Err("relay_answer_wrong_signer".into());
        }
        let verified = crate::identity::verify(
            target_public_key,
            &MeshReply::reply_message(target_node_id, caller_node_id, answer.ts, &answer.reply),
            &answer.signature,
        );
        if !verified {
            return Err("relay_answer_unverified".into());
        }
        if !wire::is_fresh(answer.ts, now_s) {
            return Err("relay_answer_stale".into());
        }
        MeshReply::parse(&answer.reply).map_err(|_| "relay_answer_unreadable".to_string())
    }
}

/// What the relay answered. `relay_refused` is the relay's own refusal (its rules on who may send at
/// all, which are not the fleet's rules on who may command whom).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RelayOutcome {
    Answered { status: u16, body: String, rid: String },
    Refused { status: u16, code: String, rid: String },
    Unavailable { reason: String, rid: String },
}

/// Send one already-signed request through the relay.
///
/// `headers` are the mesh envelope's own headers, forwarded to the target untouched; `body` is the
/// envelope. The request id the relay keys on is `request_id` — the mesh envelope's own id — so a
/// retry for one call re-fetches one result instead of running the capability twice.
pub struct RelayClient<'a> {
    pub url: String,
    pub identity: &'a Identity,
    pub connect_timeout: Duration,
    pub io_timeout: Duration,
}

impl<'a> RelayClient<'a> {
    pub fn send(
        &self,
        to_node_id: &str,
        path: &str,
        headers: &[(String, String)],
        body: &str,
        request_id: &str,
    ) -> RelayOutcome {
        let ts = wire::now_seconds().to_string();
        let signature = self
            .identity
            .sign(&format!("relay-send|{}|{ts}", self.identity.node_id));
        let header_map: serde_json::Map<String, Value> = headers
            .iter()
            .map(|(name, value)| (name.clone(), Value::String(value.clone())))
            .collect();
        let envelope = json!({
            "rid": request_id,
            "to": to_node_id,
            "method": "POST",
            "path": path,
            "headers": header_map,
            "body": body,
        })
        .to_string();
        let response = crate::http::request(
            &self.url,
            "POST",
            "/relay/send",
            &[
                ("content-type".to_string(), "application/json".to_string()),
                ("x-wa-node".to_string(), self.identity.node_id.clone()),
                ("x-wa-pub".to_string(), self.identity.public_key.clone()),
                ("x-wa-ts".to_string(), ts),
                ("x-wa-sig".to_string(), signature),
            ],
            envelope.as_bytes(),
            self.connect_timeout,
            self.io_timeout,
            crate::http::MAX_BODY,
        );
        let response = match response {
            Ok(response) => response,
            Err(error) => return RelayOutcome::Unavailable { reason: error, rid: request_id.to_string() },
        };
        let status = response.status;
        let text = response.body_text();
        let decoded: Value = match serde_json::from_str(&text) {
            Ok(value) => value,
            Err(_) => {
                return RelayOutcome::Unavailable {
                    reason: format!("relay_unreadable:{status}"),
                    rid: request_id.to_string(),
                }
            }
        };
        if status == 200 {
            if let Some(answer_status) = decoded.get("status").and_then(Value::as_u64) {
                return RelayOutcome::Answered {
                    status: answer_status as u16,
                    body: decoded.get("body").and_then(Value::as_str).unwrap_or_default().to_string(),
                    rid: request_id.to_string(),
                };
            }
        }
        match decoded.get("error").and_then(Value::as_str) {
            Some(code) => RelayOutcome::Refused {
                status,
                code: code.to_string(),
                rid: request_id.to_string(),
            },
            None => RelayOutcome::Unavailable {
                reason: format!("relay_http_{status}"),
                rid: request_id.to_string(),
            },
        }
    }
}

/// The relay a node's peers can reach it through, when it names one.
///
/// `WASM_AGENT_RELAY` first (the switch the Rust relay client already reads), then the service of an
/// accepted binding (`<config>/binding.json`'s `state.service`), which is where a managed node keeps
/// the origin it long-polls. Nothing here is discovery: it is the address of transport the operator
/// already wrote down.
pub fn configured(config: &std::path::Path) -> Option<String> {
    if let Ok(url) = std::env::var("WASM_AGENT_RELAY") {
        let url = url.trim().to_string();
        if !url.is_empty() {
            return Some(url);
        }
    }
    let path = config.join("binding.json");
    let text = std::fs::read_to_string(path).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    let state = value.get("state")?;
    let service = state.get("service")?.as_str()?.trim();
    if service.is_empty() || state.get("active").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    Some(service.trim_end_matches('/').to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::{fleet_key, Member};
    use crate::wire::MeshReply;

    fn reply() -> MeshReply {
        MeshReply {
            schema: wire::SCHEMA,
            request_id: "r1".into(),
            from_node_id: "target".into(),
            ok: true,
            status: Some(200),
            body: Some("{\"ok\":true}".into()),
            error: None,
            reason: None,
            detail: None,
            verb: Some("read".into()),
        }
    }

    #[test]
    fn a_relayed_answer_is_the_same_signed_statement_as_a_direct_one() {
        let target = Member::new("target", 1, &[]);
        let caller = Member::new("caller", 0, &[]);
        let sealed = RelayAnswer::seal(
            &target.identity,
            &target.node.node_id,
            &caller.node.node_id,
            &reply(),
        );
        let opened = RelayAnswer::open(
            &sealed.encode(),
            &target.node.node_id,
            &target.node.public_key,
            &caller.node.node_id,
            sealed.ts,
        )
        .expect("a reply signed by the target opens");
        assert_eq!(opened, reply());
        // The signed message is the direct path's, unchanged.
        let message = MeshReply::reply_message(
            &target.node.node_id,
            &caller.node.node_id,
            sealed.ts,
            &sealed.reply,
        );
        assert!(crate::identity::verify(&target.node.public_key, &message, &sealed.signature));
    }

    #[test]
    fn an_altered_or_redirected_or_stale_answer_is_not_a_result() {
        let target = Member::new("target", 1, &[]);
        let caller = Member::new("caller", 0, &[]);
        let sealed = RelayAnswer::seal(
            &target.identity,
            &target.node.node_id,
            &caller.node.node_id,
            &reply(),
        );
        let text = sealed.encode();
        let cases = [
            (text.replace("\\\"ok\\\":true", "\\\"ok\\\":false"), &target.node, &caller.node, sealed.ts),
            (text.clone(), &target.node, &Member::new("other", 1, &[]).node, sealed.ts),
            (text.clone(), &target.node, &caller.node, sealed.ts + 10_000),
        ];
        for (body, node, caller_node, now) in cases {
            let error = RelayAnswer::open(
                &body,
                &node.node_id,
                &node.public_key,
                &caller_node.node_id,
                now,
            )
            .unwrap_err();
            assert!(
                error == "relay_answer_unverified" || error == "relay_answer_stale",
                "{error}"
            );
        }
        // A stranger's key never opens it, and neither does a body that is not an answer at all.
        let stranger = fleet_key();
        assert!(RelayAnswer::open(
            &text,
            &target.node.node_id,
            &stranger.public_key,
            &caller.node.node_id,
            sealed.ts
        )
        .is_err());
        assert!(RelayAnswer::open(
            "{}",
            &target.node.node_id,
            &target.node.public_key,
            &caller.node.node_id,
            sealed.ts
        )
        .is_err());
    }
}
