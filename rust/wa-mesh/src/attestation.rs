//! The node's half of the attestation: it composes the message and **signs** it.
//!
//! The message, the bound material and the *check* are `wa-mesh-core::attest`'s, because both builds must
//! agree on the bytes (`docs/MESH.md` §9). Two things are not shared, and they are exactly the two this
//! file owns:
//!
//! * **the key.** A signature needs the node's identity, and no key crosses into a component: a guest
//!   that could sign would be a second identity for the node, and a guest that composed bytes for
//!   someone else to sign would be a signing oracle for whoever can call it. So the `wa:mesh` guest
//!   answers with the *message* ([`crate::seam::attest_message`]) and this node signs it;
//! * **the file.** `{attest: …}` mode reads the key at the path the rest of the node resolves.
use crate::identity::Identity;
use crate::seam;
use crate::wire;
use serde_json::{json, Value};

/// Sign the attestation for one admitted call: what `wa_node_call` checks (`ts` and `signature`), plus
/// the fields it refuses a mismatch on before it even verifies.
pub fn sign(
    identity: &Identity,
    caller: &str,
    verb: &str,
    capability: &str,
    caller_signature: &str,
    ts: u64,
) -> Value {
    let message = seam::attest_message(&identity.node_id, caller, verb, capability, caller_signature, ts);
    let signature = identity.sign(&message);
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
    Ok(sign(&identity, caller, verb, capability, caller_signature, wire::now_seconds()))
}

/// Check one attestation, through the seam: the `wa:mesh` guest when `WA_MESH_COMPONENT=1`, the same rule
/// natively otherwise.
#[allow(clippy::too_many_arguments)]
pub fn verify(
    node_public_key: &str,
    node_id: &str,
    caller: &str,
    verb: &str,
    capability: &str,
    caller_signature: &str,
    ts: u64,
    signature: &str,
    now_s: u64,
) -> Result<wa_mesh_core::attest::Bound, wa_mesh_core::attest::AttestError> {
    seam::verify_attestation(
        node_public_key,
        node_id,
        caller,
        verb,
        capability,
        caller_signature,
        ts,
        signature,
        now_s,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::verify;

    /// The signature this node makes and the message both builds compose are one contract, asserted as a
    /// string (the Lua verifier rebuilds exactly this).
    #[test]
    fn a_signed_attestation_binds_every_part_of_the_call() {
        let (_text, identity) = crate::identity::generate().unwrap();
        let attestation = sign(&identity, "8c11", "read", "sessions", "ab12", 1_762_000_000);
        assert_eq!(attestation["caller"], "8c11");
        assert_eq!(attestation["verb"], "read");
        assert_eq!(attestation["capability"], "sessions");
        let signature = attestation["signature"].as_str().unwrap();
        let message = wa_mesh_core::attest::message(&identity.node_id, "8c11", "read", "sessions", "ab12", 1_762_000_000);
        assert!(verify(&identity.public_key, &message, signature));
        // The seam's check says yes to the same bytes, on either path.
        assert!(super::verify(
            &identity.public_key,
            &identity.node_id,
            "8c11",
            "read",
            "sessions",
            "ab12",
            1_762_000_000,
            signature,
            1_762_000_005
        )
        .is_ok());
        // ... and no to a different capability.
        assert!(super::verify(
            &identity.public_key,
            &identity.node_id,
            "8c11",
            "read",
            "bash",
            "ab12",
            1_762_000_000,
            signature,
            1_762_000_005
        )
        .is_err());
    }
}
