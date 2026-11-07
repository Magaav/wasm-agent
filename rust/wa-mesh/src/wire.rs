//! The envelopes and the exact bytes that get signed.
//!
//! Two domains, versioned in the signed string:
//!
//! ```text
//! mesh-call-v1|<from_node_id>|<ts>|<sha256(body)>
//! mesh-reply-v1|<target node id>|<caller node id>|<ts>|<sha256(body)>
//! ```
//!
//! The body hash is inside the signature so the capability and its arguments cannot be swapped on
//! the way; `to_node_id` is inside the hashed body so a call that is valid for one node cannot be
//! delivered to another; and `v1` is in the domain so a signature can never be replayed as some
//! other kind of message (or as a roster's).
use crate::identity::sha256_hex;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const SCHEMA: u32 = 1;
pub const CALL_DOMAIN: &str = "mesh-call-v1";
pub const REPLY_DOMAIN: &str = "mesh-reply-v1";
/// Freshness window, the same tolerance `/node/call` uses: an older request is `stale_request`, and
/// a clock that is wrong by minutes is what that refusal is almost always telling you.
pub const FRESH_SECONDS: u64 = 120;
/// How long the replay guard remembers an accepted request. Twice the freshness window, so a request
/// cannot be replayed at the very edge of its own validity.
pub const REPLAY_WINDOW_SECONDS: u64 = 2 * FRESH_SECONDS;

/// Refusals a receiver can send *before* it has authenticated the caller. They cannot be signed — a
/// reply signature binds an answer to a request whose signature was verified — so a caller treats
/// them as a diagnosis (`verified: false`) and keeps only the allow-listed code, never the body.
pub const PRE_AUTH_REFUSALS: &[&str] = &[
    "bad_request",
    "bad_signature",
    "stale_request",
    "replayed_request",
    "unknown_caller",
    "wrong_target",
    "too_large",
    "not_mesh",
    "not_found",
    "roster_unverified",
    "handler_unavailable",
    "internal_error",
];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MeshCall {
    pub schema: u32,
    pub request_id: String,
    pub from_node_id: String,
    pub to_node_id: String,
    pub capability: String,
    #[serde(default)]
    pub args: Value,
    /// The ordinary `/node/call` body the caller also built and signed, carried opaquely: the target
    /// hands it to its own node path so a mesh call executes exactly like any other peer call.
    #[serde(default)]
    pub inner_body: String,
    /// The caller's own signed node headers for `inner_body`, in order. Opaque here on purpose: this
    /// crate never reads them, and whoever does gets bytes that were covered by the mesh signature.
    #[serde(default)]
    pub inner_headers: Vec<(String, String)>,
}

impl MeshCall {
    pub fn encode(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{}".to_string())
    }

    pub fn parse(text: &str) -> Result<MeshCall, String> {
        let call: MeshCall =
            serde_json::from_str(text).map_err(|error| format!("bad_request:{error}"))?;
        if call.schema != SCHEMA {
            return Err(format!("bad_request:schema {} (this build speaks {SCHEMA})", call.schema));
        }
        if call.request_id.is_empty() || call.request_id.len() > 128 {
            return Err("bad_request:request_id".into());
        }
        if call.capability.is_empty() || call.capability.len() > 128 {
            return Err("bad_request:capability".into());
        }
        if call.to_node_id.is_empty() || call.from_node_id.is_empty() {
            return Err("bad_request:node_ids".into());
        }
        Ok(call)
    }

    pub fn call_message(from_node_id: &str, ts: u64, body: &str) -> String {
        format!("{CALL_DOMAIN}|{from_node_id}|{ts}|{}", sha256_hex(body))
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MeshReply {
    pub schema: u32,
    pub request_id: String,
    pub from_node_id: String,
    pub ok: bool,
    /// The inner call's HTTP status (`/node/call` answers 200 for a completed capability call and
    /// something else for a refusal it made itself). The mesh layer's own status is the transport's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verb: Option<String>,
}

impl MeshReply {
    /// A refusal after the caller was authenticated: signed, with the reason word that matches the
    /// hierarchy's own vocabulary, so a caller can tell a decision from something the network said.
    pub fn refusal(
        request_id: &str,
        from_node_id: &str,
        code: &str,
        reason: &str,
        detail: &str,
        verb: &str,
    ) -> MeshReply {
        MeshReply {
            schema: SCHEMA,
            request_id: request_id.to_string(),
            from_node_id: from_node_id.to_string(),
            ok: false,
            status: None,
            body: None,
            error: Some(code.to_string()),
            reason: Some(reason.to_string()),
            detail: Some(detail.to_string()),
            verb: Some(verb.to_string()),
        }
    }

    pub fn encode(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{}".to_string())
    }

    pub fn parse(text: &str) -> Result<MeshReply, String> {
        serde_json::from_str(text).map_err(|error| format!("bad_reply:{error}"))
    }

    pub fn reply_message(target_node_id: &str, caller_node_id: &str, ts: u64, body: &str) -> String {
        format!("{REPLY_DOMAIN}|{target_node_id}|{caller_node_id}|{ts}|{}", sha256_hex(body))
    }
}

/// The `error` code of an unsigned body, allow-listed by shape *and* by name. Returns `None` for
/// anything that is not one of the codes this layer can send, so a forged or altered refusal cannot
/// put arbitrary text in front of a model or an operator.
pub fn pre_auth_code(body: &str) -> Option<&'static str> {
    let value: Value = serde_json::from_str(body).ok()?;
    let code = value.get("error")?.as_str()?;
    PRE_AUTH_REFUSALS
        .iter()
        .copied()
        .find(|candidate| *candidate == code)
}

pub fn now_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

pub fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

pub fn is_fresh(ts: u64, now: u64) -> bool {
    now.abs_diff(ts) <= FRESH_SECONDS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_signed_message_names_the_domain_the_caller_and_the_body() {
        let body = r#"{"schema":1,"request_id":"r1","from_node_id":"aa","to_node_id":"bb","capability":"read"}"#;
        let message = MeshCall::call_message("aa", 1_762_000_000, body);
        assert_eq!(
            message,
            format!("mesh-call-v1|aa|1762000000|{}", sha256_hex(body))
        );
        let reply = MeshReply::reply_message("bb", "aa", 1_762_000_000, "{}");
        assert!(reply.starts_with("mesh-reply-v1|bb|aa|1762000000|"));
        // A body that changes changes the message; a timestamp that changes changes the message.
        assert_ne!(message, MeshCall::call_message("aa", 1_762_000_001, body));
        assert_ne!(message, MeshCall::call_message("aa", 1_762_000_000, &body.replace("read", "bash")));
    }

    #[test]
    fn an_envelope_round_trips_and_refuses_a_stranger_field() {
        let call = MeshCall {
            schema: SCHEMA,
            request_id: "r1".into(),
            from_node_id: "aa".into(),
            to_node_id: "bb".into(),
            capability: "read".into(),
            args: serde_json::json!({"path": "README.md"}),
            inner_body: "{}".into(),
            inner_headers: vec![("X-WA-Node".into(), "aa".into())],
        };
        let text = call.encode();
        assert_eq!(MeshCall::parse(&text).unwrap(), call);
        assert!(MeshCall::parse(&text.replace("\"capability\"", "\"capabilty\"")).is_err());
        assert!(MeshCall::parse("not json").is_err());
        assert!(MeshCall::parse(&text.replace("\"schema\":1", "\"schema\":2")).is_err());
    }

    #[test]
    fn only_this_layers_own_codes_come_back_from_an_unsigned_body() {
        assert_eq!(pre_auth_code(r#"{"error":"bad_signature"}"#), Some("bad_signature"));
        assert_eq!(pre_auth_code(r#"{"error":"<script>"}"#), None);
        assert_eq!(pre_auth_code(r#"{"error":"read the docs at ..."}"#), None);
        assert_eq!(pre_auth_code("not json"), None);
        assert!(is_fresh(1_000, 1_120));
        assert!(!is_fresh(1_000, 1_121));
    }
}
