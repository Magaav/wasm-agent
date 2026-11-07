//! The attestation a node's mount signs after `authorize()` said allow.
//!
//! `docs/MESH.md` §9 (and §8.1) names the last seam between the mesh's verdict and a *managed* node's
//! capability list: `wa_node_call` has always admitted an inbound peer call by a list of capability
//! *names*, because a name list is all it had. A verified fleet roster and a verified roster+grant
//! decision exist for a mesh call, so the call is admitted by the **verb** the mesh decided on
//! (`read`, `control`, `call`) — but only with proof that the mesh decided it, for this caller, this
//! capability and this exact request.
//!
//! That proof is this signature, made with the node's own identity key:
//!
//! ```text
//! mesh-allow|<this node id>|<unix seconds>|<sha256(caller|verb|capability|<the caller's x-wa-sig>)>
//! ```
//!
//! It is the same shape every other peer signature in `lua/core/server.lua` uses (`signature_matches`
//! hashes the last part and puts the domain and the signer's id in front), so the Lua verifier needs
//! no special case — and the Lua admission test (`scripts/test-mesh-verb-admission.lua`) has pinned
//! that shape since the seam was written. What was missing was the producer: this module, called by
//! the mount only after [`crate::admission`] returned [`crate::admission::Admission::Allow`].
//!
//! Why signing it is not a new power for a caller: a remote caller cannot mint one (it holds its own
//! key, and the message names *this* node id), a local process cannot without the node key that every
//! other peer check already rests on, and it is bound to one caller, one verb, one capability name and
//! the caller's own request signature, so it cannot be replayed onto a different request, capability
//! or verb. Without one, `wa_node_call` falls back to the unchanged legacy list.
use crate::identity::{sha256_hex, Identity};
use serde_json::{json, Value};

/// The domain string in front of every attestation, so one can never be replayed as a call, a reply or
/// a roster.
pub const ATTEST_DOMAIN: &str = "mesh-allow";

/// The bound material: what the attestation is *about*.
pub fn material(caller: &str, verb: &str, capability: &str, caller_signature: &str) -> String {
    format!("{caller}|{verb}|{capability}|{caller_signature}")
}

/// The exact bytes signed, as `lua/core/server.lua::signature_matches` reconstructs them for
/// `action = "mesh-allow"`, `from = <this node id>`, `ts = <ts>` and `body = material(…)`.
pub fn message(node_id: &str, caller: &str, verb: &str, capability: &str, caller_signature: &str, ts: u64) -> String {
    format!(
        "{ATTEST_DOMAIN}|{node_id}|{ts}|{}",
        sha256_hex(&material(caller, verb, capability, caller_signature))
    )
}

/// Sign the attestation for one admitted call. The `ts` and the signature are what `wa_node_call`
/// checks; `caller`, `verb` and `capability` are carried so the receiver can refuse a mismatch before
/// it even verifies the signature.
pub fn sign(
    identity: &Identity,
    caller: &str,
    verb: &str,
    capability: &str,
    caller_signature: &str,
    ts: u64,
) -> Value {
    let signature = identity.sign(&message(identity.node_id.as_str(), caller, verb, capability, caller_signature, ts));
    json!({
        "caller": caller,
        "verb": verb,
        "capability": capability,
        "ts": ts,
        "signature": signature,
    })
}

/// The same attestation for the node whose key file is at `paths.key` — what `host.mesh_call`'s
/// `{attest: …}` mode answers, and the one form the Lua test in `scripts/` can obtain from Rust.
pub fn from_files(
    paths: &crate::host_call::Paths,
    caller: &str,
    verb: &str,
    capability: &str,
    caller_signature: &str,
) -> Result<Value, String> {
    let identity = Identity::open(&paths.key)?;
    Ok(sign(&identity, caller, verb, capability, caller_signature, crate::wire::now_seconds()))
}

/// The caller's own request signature, out of the headers the envelope carried. Empty is a valid
/// answer (and then the attestation binds the empty string, which the receiver recomputes the same
/// way, so nothing is admitted by accident).
pub fn caller_signature(headers: &[(String, String)]) -> String {
    headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("x-wa-sig"))
        .map(|(_, value)| value.trim().to_string())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::verify;

    /// The message is exactly the one the Lua verifier builds. This is the whole contract of the
    /// seam, so it is asserted as a string and not only as "verify() said yes".
    #[test]
    fn the_signed_message_is_the_lua_verifiers_message() {
        let material = material("8c11", "read", "sessions", "ab12");
        assert_eq!(material, "8c11|read|sessions|ab12");
        assert_eq!(
            message("3f2a", "8c11", "read", "sessions", "ab12", 1762000000),
            format!(
                "mesh-allow|3f2a|1762000000|{}",
                sha256_hex("8c11|read|sessions|ab12")
            )
        );
    }

    #[test]
    fn a_signed_attestation_verifies_only_for_what_it_names() {
        let node = crate::testkit::identity("attest-node");
        let attestation = sign(&node, "8c11", "read", "sessions", "ab12", 1_762_000_000);
        assert_eq!(attestation["caller"], "8c11");
        assert_eq!(attestation["verb"], "read");
        assert_eq!(attestation["capability"], "sessions");
        assert_eq!(attestation["ts"], 1_762_000_000);
        let signature = attestation["signature"].as_str().unwrap();
        assert!(verify(
            &node.public_key,
            &message(&node.node_id, "8c11", "read", "sessions", "ab12", 1_762_000_000),
            signature
        ));
        // Every part is bound: another caller, verb, capability, request signature or timestamp fails.
        for other in [
            message(&node.node_id, "ffff", "read", "sessions", "ab12", 1_762_000_000),
            message(&node.node_id, "8c11", "control", "sessions", "ab12", 1_762_000_000),
            message(&node.node_id, "8c11", "read", "bash", "ab12", 1_762_000_000),
            message(&node.node_id, "8c11", "read", "sessions", "ef34", 1_762_000_000),
            message(&node.node_id, "8c11", "read", "sessions", "ab12", 1_762_000_001),
        ] {
            assert!(!verify(&node.public_key, &other, signature), "{other}");
        }
        // And another node's key cannot speak for this node.
        let other = crate::testkit::identity("attest-other");
        assert!(!verify(
            &other.public_key,
            &message(&node.node_id, "8c11", "read", "sessions", "ab12", 1_762_000_000),
            signature
        ));
    }

    #[test]
    fn the_caller_signature_comes_out_of_the_headers_case_insensitively() {
        let headers = vec![
            ("x-wa-node".to_string(), "8c11".to_string()),
            ("X-WA-Sig".to_string(), "  deadbeef ".to_string()),
        ];
        assert_eq!(caller_signature(&headers), "deadbeef");
        assert_eq!(caller_signature(&[]), "");
    }
}
