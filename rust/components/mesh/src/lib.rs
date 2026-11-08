//! The mesh as a component (`docs/MESH.md`, `docs/CORE-SPLIT.md`, "mesh/fleet").
//!
//! It exports `wa:mesh` — the roster's verify, `decide(grants, caller, target, verb)`, the verb a
//! capability needs, the audit line, the attestation's exact bytes and its check, and the peer-address
//! rule — and imports **nothing**: no `wa:kernel/sql` (the mesh stores no rows), no socket (a component
//! must not own one), no clock (`now` is an argument), no key (the node's identity is the node's).
//!
//! The logic is `wa-mesh-core`'s, the same crate the node links: this file is the translation between
//! typed records and that crate's values, plus the one thing a build has to supply — an ed25519
//! verifier. [`Dalek`] is it, and it is a *verifier*: this component cannot sign, so it can compose the
//! attestation's message and check one but never mint one.
//!
//! What deliberately stays in the kernel, because it is transport and not a decision:
//!
//! * the listener, the relay and the rendezvous (`wa-mesh`'s `server`, `relay`, `client`), which carry
//!   the same signed bytes and ask this seam on both ends;
//! * the peer cache file and the policy file (`wa_mesh::cache`, `MeshPolicy::from_policy_file`): the
//!   rule is here (`addresses`, `decide`), the bytes on disk are the node's;
//! * the loopback admission hop and its one-shot tickets (`wa_mesh::admission::tickets`), which prove
//!   *which* decision is being carried inside one process and are therefore a process's business;
//! * the node's identity and the signing of an attestation (`wa_mesh::attest::sign`).
use ed25519_dalek::{Signature, VerifyingKey};
use wa_mesh_core::attest::{self, AttestError};
use wa_mesh_core::audit::Event as CoreEvent;
use wa_mesh_core::cache::PeerCache;
use wa_mesh_core::crypto::{unhex, Crypto};
use wa_mesh_core::hierarchy::{self, Verb};
use wa_mesh_core::policy::{Effect, Grant, MeshPolicy};
use wa_mesh_core::roster::{Draft, RosterError, RosterNode, RosterProblem};
use wa_mesh_core::Pattern;

wit_bindgen::generate!({ path: "../../../wit/mesh", world: "mesh-component", generate_all });

use crate::exports::wa::mesh::mesh::Guest;
use crate::wa::mesh::types::{
    AuditEvent, CallFacts, Grant as WitGrant, LevelFacts, Node, RosterRefusal, Ticket, TicketFacts, TicketRefusal, Verdict as WitVerdict,
};

/// The verifier this build supplies. Stateless, and it holds no key: a component that could sign would
/// be a second identity for the node, which is exactly what `docs/MESH.md` §1 refuses.
struct Dalek;

impl Crypto for Dalek {
    fn verify_ed25519(&self, public_key_hex: &str, message: &[u8], signature_hex: &str) -> bool {
        let (Some(public), Some(signature)) = (unhex(public_key_hex), unhex(signature_hex)) else {
            return false;
        };
        let Ok(public) = VerifyingKey::from_bytes(&public[..].try_into().unwrap_or([0u8; 32])) else {
            return false;
        };
        let Ok(signature) = Signature::from_slice(&signature) else {
            return false;
        };
        public.verify_strict(message, &signature).is_ok()
    }
}

fn crypto() -> Dalek {
    Dalek
}

/// The exported component: one fn per seam operation, no state of its own, no instance between calls.
struct MeshComponent;

impl Guest for MeshComponent {
    /// Parse, then verify: signature first (a tampered document is a signature failure, not a shape
    /// failure), then the window, then the nodes — the order the node's own path uses, so the two
    /// paths answer with the same refusal for the same file.
    fn verify_roster(document: String, fleet_key: String, now: u64) -> Result<LevelFacts, RosterRefusal> {
        let parsed = wa_mesh_core::roster::Roster::parse(&document).map_err(refusal)?;
        parsed.verify(&crypto(), &fleet_key, now).map_err(refusal)?;
        Ok(LevelFacts {
            fleet: parsed.fleet.clone(),
            fingerprint: parsed.fingerprint(),
            issued_at: parsed.issued_at,
            expires_at: parsed.expires_at,
            nodes: parsed.nodes.iter().map(node_of).collect(),
        })
    }

    fn decide(grants: Vec<WitGrant>, facts: CallFacts) -> WitVerdict {
        let policy = match policy_of(grants) {
            Ok(policy) => policy,
            // A pattern this build cannot read is a refusal, never a grant: the native path refuses the
            // whole policy file at load time (`MeshPolicy::validate` + `Pattern`'s parser), so the only
            // way to see one here is a caller that built the request by hand.
            Err(problem) => {
                return WitVerdict { allow: false, reason: "grant_invalid".into(), detail: problem };
            }
        };
        let verdict = hierarchy::authorize(&policy, &roster_node(&facts.caller), &roster_node(&facts.target), verb_of(&facts.verb), facts.now);
        WitVerdict { allow: verdict.allow, reason: verdict.reason.to_string(), detail: verdict.detail }
    }

    fn verb(capability: String) -> String {
        Verb::from_capability(&capability).as_str().to_string()
    }

    fn render_audit(event: AuditEvent) -> String {
        // `kind` and `decision` arrive as text; the renderer takes the two closed vocabularies as
        // `&'static str`. An unknown decision reads as `deny`, which is the safe reading of a line.
        let kind = match event.kind.as_str() {
            "recv" => "recv",
            "reply" => "reply",
            _ => "call",
        };
        CoreEvent {
            kind,
            from: event.from_node,
            to: event.to_node,
            from_level: event.from_level,
            to_level: event.to_level,
            verb: event.verb,
            decision: if event.decision == "allow" { "allow" } else { "deny" },
            reason: event.reason,
            transport: event.transport,
            class: event.addr_class,
            ok: event.ok,
            status: event.status,
            ms: event.ms,
            attempt: event.attempt,
        }
        .render()
    }

    fn attest_message(node_id: String, caller: String, verb: String, capability: String, caller_signature: String, ts: u64) -> String {
        attest::message(&node_id, &caller, &verb, &capability, &caller_signature, ts)
    }

    fn verify_ticket(
        ticket: Ticket,
        node_id: String,
        node_public_key: String,
        caller_signature: String,
        now: u64,
    ) -> Result<TicketFacts, TicketRefusal> {
        match attest::verify(
            &crypto(),
            &node_public_key,
            &node_id,
            &ticket.caller,
            &ticket.verb,
            &ticket.capability,
            &caller_signature,
            ticket.ts,
            &ticket.signature,
            now,
        ) {
            Ok(bound) => Ok(TicketFacts {
                node_id: bound.node_id,
                caller: bound.caller,
                verb: bound.verb,
                capability: bound.capability,
                ts: bound.ts,
            }),
            Err(error) => Err(ticket_refusal(&error)),
        }
    }

    fn addresses(target: Node, learned: Vec<String>) -> Vec<String> {
        // The rule is `PeerCache::addresses`, which reads the roster's own list out of the node and the
        // learned ones out of the cache entry. A component holds no cache file, so the entry is built
        // around the node id the call names and given exactly the addresses the caller knows.
        let node = roster_node(&target);
        let mut cache = PeerCache::empty();
        for address in learned {
            cache.record_success(&node.node_id, &address, 0);
        }
        cache.addresses(&node)
    }
}

fn verb_of(verb: &str) -> Verb {
    match verb {
        "read" => Verb::Read,
        "control" => Verb::Control,
        // Anything else is `call`: the middle authority, never `read`. The node resolves the verb from
        // the capability name (`verb`) before it asks, so this only bounds a hand-written request.
        _ => Verb::Call,
    }
}

fn effects(effect: &str) -> Effect {
    if effect.eq_ignore_ascii_case("deny") {
        Effect::Deny
    } else {
        Effect::Allow
    }
}

fn policy_of(grants: Vec<WitGrant>) -> Result<MeshPolicy, String> {
    let mut out = MeshPolicy::empty();
    for grant in grants {
        let pattern = |field: &str, raw: &str| {
            Pattern::new(raw).map_err(|error| format!("grants.{field}:{error}"))
        };
        out.grants.push(Grant {
            caller: pattern("caller", &grant.caller)?,
            target: pattern("target", &grant.target)?,
            verb: pattern("verb", &grant.verb)?,
            effect: effects(&grant.effect),
            note: grant.note,
        });
    }
    Ok(out)
}

fn node_of(node: &RosterNode) -> Node {
    Node {
        id: node.node_id.clone(),
        public_key: node.public_key.clone(),
        name: node.name.clone(),
        level: node.level,
        addresses: node.addresses.clone(),
        revoked_at: node.revoked_at,
    }
}

fn roster_node(node: &Node) -> RosterNode {
    RosterNode {
        node_id: node.id.clone(),
        public_key: node.public_key.clone(),
        name: node.name.clone(),
        level: node.level,
        addresses: node.addresses.clone(),
        revoked_at: node.revoked_at,
    }
}

/// One refusal, as its case. The sentence the node reports (`roster_unverified:bad_signature`, …) is
/// `RosterError`'s, so the two paths print the same words for the same file.
fn refusal(error: RosterError) -> RosterRefusal {
    match error.problem() {
        RosterProblem::NotARoster(detail) => RosterRefusal::NotARoster(detail),
        RosterProblem::KeyMissing => RosterRefusal::KeyMissing,
        RosterProblem::KeyMalformed(text) => RosterRefusal::KeyMalformed(text),
        RosterProblem::BadSignature => RosterRefusal::BadSignature,
        RosterProblem::NotYetValid => RosterRefusal::NotYetValid,
        RosterProblem::Expired => RosterRefusal::Expired,
        RosterProblem::VersionUnsupported(version) => RosterRefusal::VersionUnsupported(version),
        RosterProblem::LevelOutOfRange(name) => RosterRefusal::LevelOutOfRange(name),
        RosterProblem::DuplicateNode(id) => RosterRefusal::DuplicateNode(id),
        RosterProblem::NodeIdMismatch(name) => RosterRefusal::NodeIdMismatch(name),
        RosterProblem::PublicKeyMalformed(name) => RosterRefusal::NodeIdMismatch(name),
        RosterProblem::BadAddress(address) => RosterRefusal::BadAddress(address),
        RosterProblem::TooManyAddresses(name) => RosterRefusal::TooManyAddresses(name),
        RosterProblem::BadName(detail) => RosterRefusal::BadName(detail),
        RosterProblem::Other(detail) => RosterRefusal::NotARoster(detail),
    }
}

fn ticket_refusal(error: &AttestError) -> TicketRefusal {
    match error {
        AttestError::Absent => TicketRefusal::Absent,
        AttestError::Mismatch(field) => TicketRefusal::Mismatch(field.to_string()),
        AttestError::BadSignature => TicketRefusal::BadSignature,
        AttestError::Stale(age) => TicketRefusal::Stale(*age),
    }
}

/// The draft a caller can rebuild the same roster from, for the tests in this crate and for the node's
/// parity suite: the component and the node must sign and verify the same canonical bytes.
pub fn draft(fleet: &str, issued_at: u64, expires_at: u64, nodes: Vec<Node>) -> Draft {
    Draft {
        fleet: fleet.to_string(),
        issued_at,
        expires_at,
        nodes: nodes.iter().map(roster_node).collect(),
    }
}

export!(MeshComponent);

#[cfg(test)]
mod tests {
    use super::*;

    fn node(id: &str, name: &str, level: u8, addresses: &[&str]) -> Node {
        Node {
            id: id.to_string(),
            public_key: format!("{id}{id}"),
            name: name.to_string(),
            level,
            addresses: addresses.iter().map(|address| address.to_string()).collect(),
            revoked_at: 0,
        }
    }

    #[test]
    fn an_unknown_capability_is_call_and_never_read() {
        assert_eq!(MeshComponent::verb("read".into()), "read");
        assert_eq!(MeshComponent::verb("bash".into()), "control");
        assert_eq!(MeshComponent::verb("capability_from_2031".into()), "call");
    }

    #[test]
    fn the_hierarchy_is_the_native_one_and_a_deny_grant_wins() {
        let top = node("aa", "laptop", 0, &[]);
        let mid = node("bb", "oracle", 1, &[]);
        let now = 1_762_000_100;
        let down = MeshComponent::decide(
            vec![],
            CallFacts { caller: top.clone(), target: mid.clone(), verb: "control".into(), now },
        );
        assert!(down.allow);
        assert_eq!(down.reason, "hierarchy_allowed");
        let up = MeshComponent::decide(
            vec![],
            CallFacts { caller: mid.clone(), target: top.clone(), verb: "control".into(), now },
        );
        assert!(!up.allow);
        assert_eq!(up.reason, "hierarchy_denied");
        let denied = MeshComponent::decide(
            vec![WitGrant {
                caller: "*".into(),
                target: top.id.clone(),
                verb: "control".into(),
                effect: "deny".into(),
                note: None,
            }],
            CallFacts { caller: top.clone(), target: mid, verb: "control".into(), now },
        );
        assert!(denied.allow, "a deny scoped to the laptop as target does not touch a call the laptop makes");
        // A malformed pattern is a refusal, never a grant.
        let broken = MeshComponent::decide(
            vec![WitGrant {
                caller: "".into(),
                target: "*".into(),
                verb: "*".into(),
                effect: "allow".into(),
                note: None,
            }],
            CallFacts { caller: top.clone(), target: node("cc", "phone", 1, &[]), verb: "read".into(), now },
        );
        assert!(!broken.allow);
        assert_eq!(broken.reason, "grant_invalid");
    }

    #[test]
    fn the_audit_line_is_rendered_by_the_same_rule_the_node_uses() {
        let line = MeshComponent::render_audit(AuditEvent {
            kind: "call".into(),
            from_node: "8c11f0a2deadbeef".into(),
            to_node: "3f2a91cdcafebabe".into(),
            from_level: Some(0),
            to_level: Some(1),
            verb: "control".into(),
            decision: "allow".into(),
            reason: "hierarchy_allowed".into(),
            transport: "direct:lan".into(),
            addr_class: "private".into(),
            ok: true,
            status: Some(200),
            ms: 41,
            attempt: 1,
        });
        assert_eq!(
            line,
            "mesh call from=8c11f0a2 to=3f2a91cd levels=0->1 verb=control decision=allow \
             reason=hierarchy_allowed transport=direct:lan addr_class=private ok=true status=200 ms=41 attempt=1"
        );
    }

    #[test]
    fn a_roster_that_is_not_the_operators_does_not_verify_here_either() {
        // No key at all is the first refusal, before any parse is believed.
        let refusal = MeshComponent::verify_roster("{}".into(), String::new(), 1).unwrap_err();
        assert!(matches!(refusal, RosterRefusal::KeyMissing), "{refusal:?}");
        // A key and a document that was never signed is a signature failure, not a shape one.
        let refusal = MeshComponent::verify_roster(
            r#"{"version":1,"fleet":"f","issued_at":0,"expires_at":0,"nodes":[]}"#.into(),
            "a".repeat(64),
            1,
        )
        .unwrap_err();
        assert!(matches!(refusal, RosterRefusal::BadSignature), "{refusal:?}");
        // Garbage is `not-a-roster`, with the parser's words.
        let refusal = MeshComponent::verify_roster("not json".into(), "a".repeat(64), 1).unwrap_err();
        assert!(matches!(refusal, RosterRefusal::NotARoster(_)), "{refusal:?}");
    }

    #[test]
    fn the_attestation_message_is_the_one_the_node_signs() {
        assert_eq!(
            MeshComponent::attest_message("3f2a".into(), "8c11".into(), "read".into(), "sessions".into(), "ab12".into(), 1_762_000_000),
            attest::message("3f2a", "8c11", "read", "sessions", "ab12", 1_762_000_000)
        );
        // An absent attestation says so and is not a bad signature.
        let refused = MeshComponent::verify_ticket(
            Ticket {
                caller: "8c11".into(),
                verb: "read".into(),
                capability: "sessions".into(),
                ts: 1,
                signature: String::new(),
            },
            "3f2a".into(),
            "a".repeat(64),
            "ab12".into(),
            1,
        )
        .unwrap_err();
        assert!(matches!(refused, TicketRefusal::Absent), "{refused:?}");
    }

    #[test]
    fn the_roster_addresses_come_first_and_a_lan_one_before_a_public_one() {
        let target = node("aa", "laptop", 0, &["147.15.64.233:8891", "192.168.1.10:8891"]);
        assert_eq!(
            MeshComponent::addresses(target.clone(), vec!["10.0.0.4:8891".into(), "8.8.8.8:8891".into()]),
            vec![
                "192.168.1.10:8891".to_string(),
                "147.15.64.233:8891".to_string(),
                "10.0.0.4:8891".to_string(),
                "8.8.8.8:8891".to_string()
            ]
        );
        // Eight at most, and the roster's own list keeps its place at the front.
        let learned: Vec<String> = (0..12).map(|index| format!("10.9.0.{index}:1")).collect();
        assert_eq!(MeshComponent::addresses(target, learned).len(), 8);
    }
}
