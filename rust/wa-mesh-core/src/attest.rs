//! The attestation a node's mount signs after `authorize()` said allow, and the check of one.
//!
//! `docs/MESH.md` §9 (and §8.1) names the last seam between the mesh's verdict and a *managed* node's
//! capability list: `wa_node_call` has always admitted an inbound peer call by a list of capability
//! *names*, because a name list is all it had. A verified fleet roster and a verified roster+grant
//! decision exist for a mesh call, so the call is admitted by the **verb** the mesh decided on
//! (`read`, `control`, `call`) — but only with proof that the mesh decided it, for this caller, this
//! capability and this exact request.
//!
//! That proof is a signature made with the node's own identity key:
//!
//! ```text
//! mesh-allow|<this node id>|<unix seconds>|<sha256(caller|verb|capability|<the caller's x-wa-sig>)>
//! ```
//!
//! It is the same shape every other peer signature in `lua/core/server.lua` uses (`signature_matches`
//! hashes the last part and puts the domain and the signer's id in front), so the Lua verifier needs
//! no special case — and the Lua admission test (`scripts/test-mesh-verb-admission.lua`) has pinned
//! that shape since the seam was written.
//!
//! **Where the key is.** The message, the bound material and the check are here, because they are the
//! rule and both sides must agree on them byte for byte. The *signature* is not: it is made by the
//! node's identity (`wa-mesh`'s `attest::sign`), and no key ever reaches the `wa:mesh` guest. A guest
//! that built the bytes and asked someone else to sign them would be a signing oracle for whoever can
//! call it; a guest that holds a key would be a second identity. So the component composes and
//! verifies, the node signs.
use crate::crypto::{sha256_hex, Crypto};

/// The domain string in front of every attestation, so one can never be replayed as a call, a reply or
/// a roster.
pub const ATTEST_DOMAIN: &str = "mesh-allow";

/// How old a presented attestation may be. The window belongs with the message, not with the
/// transport: an attestation is handed from the listener to the local hop, which is milliseconds, and
/// a captured one must not be usable later.
pub const ATTEST_MAX_AGE_SECONDS: u64 = 300;

/// How long an attestation may be *spent* as an execution trust basis, in seconds (meshtrust).
///
/// Shorter than a peer request's freshness window (`wa_mesh::wire::FRESH_SECONDS`, 120 s) on purpose:
/// that window bounds a request that may cross a slow network, while this proof is minted for one
/// loopback hop and spent immediately. `lua/core/server.lua` enforces the same bound
/// (`ATTESTATION_SECONDS`) because the trust decision happens there; [`ATTEST_MAX_AGE_SECONDS`] stays
/// the outer bound for `verify`. Single use is enforced where it is spent (the one-shot admission
/// ticket and the Lua replay ledger), not here.
pub const TTL_SECONDS: u64 = 60;
const _: () = assert!(TTL_SECONDS < ATTEST_MAX_AGE_SECONDS);

/// Is this attestation still inside its spending window? (`|now - ts| <= TTL_SECONDS`.)
pub fn is_fresh(ts: u64, now_s: u64) -> bool {
    now_s.abs_diff(ts) <= TTL_SECONDS
}

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

/// What a verified attestation admits, in the words the local hop uses. It is the *bound* half of the
/// attestation: the facts the signature covered, never the signature itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bound {
    pub node_id: String,
    pub caller: String,
    pub verb: String,
    pub capability: String,
    pub ts: u64,
}

/// Every reason an attestation is refused, as a slug the refusal body already uses. A refusal is a
/// verdict: nothing here falls back to the legacy name list (that is the caller's decision, made on
/// "no attestation was presented" alone).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttestError {
    /// No attestation at all: the local hop may fall back to the legacy capability list.
    Absent,
    /// A field the attestation carries does not match the call it accompanies.
    Mismatch(&'static str),
    /// The signature does not verify against this node's key.
    BadSignature,
    /// Signed too long ago (or in the future); `skew` says by how much.
    Stale(u64),
}

impl AttestError {
    pub fn slug(&self) -> &'static str {
        match self {
            AttestError::Absent => "attestation_absent",
            AttestError::Mismatch(field) => mismatch_slug(field),
            AttestError::BadSignature => "attestation_bad_signature",
            AttestError::Stale(_) => "attestation_stale",
        }
    }
}

/// The slug for the field an attestation disagrees about, so a component's typed refusal and the node's
/// string refusal are one vocabulary (the component cannot carry a `&'static str` back).
pub fn mismatch_slug(field: &str) -> &'static str {
    match field {
        "caller" => "attestation_caller",
        "verb" => "attestation_verb",
        "capability" => "attestation_capability",
        _ => "attestation_mismatch",
    }
}

/// Check one attestation: its bound fields against the call it accompanies, then its signature against
/// *this* node's public key, then its window. The order mirrors the roster's (authentic before
/// consistent), so a tampered attestation is `bad_signature` rather than a field mismatch it could be
/// made to look like.
#[allow(clippy::too_many_arguments)]
pub fn verify(
    crypto: &dyn Crypto,
    node_public_key: &str,
    node_id: &str,
    caller: &str,
    verb: &str,
    capability: &str,
    caller_signature: &str,
    ts: u64,
    signature: &str,
    now_s: u64,
) -> Result<Bound, AttestError> {
    if signature.trim().is_empty() {
        return Err(AttestError::Absent);
    }
    if caller.is_empty() {
        return Err(AttestError::Mismatch("caller"));
    }
    if verb.is_empty() {
        return Err(AttestError::Mismatch("verb"));
    }
    if capability.is_empty() {
        return Err(AttestError::Mismatch("capability"));
    }
    let message = message(node_id, caller, verb, capability, caller_signature, ts);
    if !crypto.verify_ed25519(node_public_key, message.as_bytes(), signature) {
        return Err(AttestError::BadSignature);
    }
    let age = now_s.abs_diff(ts);
    if age > ATTEST_MAX_AGE_SECONDS {
        return Err(AttestError::Stale(age));
    }
    Ok(Bound {
        node_id: node_id.to_string(),
        caller: caller.to_string(),
        verb: verb.to_string(),
        capability: capability.to_string(),
        ts,
    })
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
    use crate::crypto::Signer;
    use crate::testkit::{crypto, TestKey};

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
        let node = TestKey::named("attest-node");
        let now = 1_762_000_000u64;
        let signature = node.sign(&message(&node.node_id, "8c11", "read", "sessions", "ab12", now));
        let bound = verify(
            &crypto(),
            &node.public_key,
            &node.node_id,
            "8c11",
            "read",
            "sessions",
            "ab12",
            now,
            &signature,
            now + 5,
        )
        .expect("a fresh, bound attestation");
        assert_eq!(bound.caller, "8c11");
        assert_eq!(bound.verb, "read");
        assert_eq!(bound.capability, "sessions");
        assert_eq!(bound.ts, now);

        // Every part is bound: another caller, verb, capability, request signature or timestamp fails.
        for (caller, verb, capability, request, ts) in [
            ("ffff", "read", "sessions", "ab12", now),
            ("8c11", "control", "sessions", "ab12", now),
            ("8c11", "read", "bash", "ab12", now),
            ("8c11", "read", "sessions", "ef34", now),
            ("8c11", "read", "sessions", "ab12", now + 1),
        ] {
            let verdict = verify(
                &crypto(),
                &node.public_key,
                &node.node_id,
                caller,
                verb,
                capability,
                request,
                ts,
                &signature,
                now,
            );
            assert_eq!(verdict, Err(AttestError::BadSignature), "{caller}/{verb}/{capability}");
        }
        // An absent attestation says so, and is not a bad signature.
        assert_eq!(
            verify(&crypto(), &node.public_key, &node.node_id, "8c11", "read", "sessions", "ab12", now, "", now),
            Err(AttestError::Absent)
        );
        // Another node's key cannot speak for this node.
        let other = TestKey::named("attest-other");
        assert_eq!(
            verify(
                &crypto(),
                &other.public_key,
                &node.node_id,
                "8c11",
                "read",
                "sessions",
                "ab12",
                now,
                &signature,
                now
            ),
            Err(AttestError::BadSignature)
        );
        // A correctly signed but old attestation is stale, with its age.
        assert_eq!(
            verify(
                &crypto(),
                &node.public_key,
                &node.node_id,
                "8c11",
                "read",
                "sessions",
                "ab12",
                now,
                &signature,
                now + ATTEST_MAX_AGE_SECONDS + 1
            ),
            Err(AttestError::Stale(ATTEST_MAX_AGE_SECONDS + 1))
        );
    }

    #[test]
    fn the_attestation_window_is_shorter_than_a_peer_requests_and_is_a_hard_bound() {
        // One loopback hop; must stay inside a peer request's 120 s freshness window (wa_mesh::wire).
        const _: () = assert!(TTL_SECONDS < 120);
        let now = 1_762_000_000;
        assert!(is_fresh(now, now));
        assert!(is_fresh(now.saturating_sub(TTL_SECONDS), now), "the window's near edge is inside it");
        assert!(is_fresh(now + TTL_SECONDS, now), "a clock ahead by the window is still inside it");
        assert!(!is_fresh(now.saturating_sub(TTL_SECONDS + 1), now), "one second past it is expired");
        assert!(!is_fresh(now + TTL_SECONDS + 1, now));
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
