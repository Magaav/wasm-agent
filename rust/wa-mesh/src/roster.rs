//! The signed fleet roster: who is in the fleet, at what level, and where.
//!
//! One document, one signature, one key — the operator's fleet key. A node cannot declare its own
//! level: the level is in a file the node cannot sign, and the rendezvous is never asked. The
//! canonical bytes are in `docs/MESH.md` §1; the domain string in front of them is what stops a
//! roster signature from ever being accepted as a call signature.
//!
//! Everything strict here is strict on purpose: unknown fields, a duplicate node, a `node_id` that
//! is not the hash of its `public_key`, a level above [`MAX_LEVEL`] and a malformed address are all
//! load errors. A roster is the authority on who may command whom, so a typo in it must be visible
//! rather than silently weaker or stronger than the operator meant.
use crate::identity::{derive_node_id, sha256_hex, unhex, verify, Identity};
use serde::{Deserialize, Serialize};
use std::path::Path;

/// Schema of the document.
pub const ROSTER_SCHEMA: u32 = 1;
/// The domain string that is part of every signed roster.
pub const ROSTER_DOMAIN: &str = "mesh-roster-v1";
/// The domain string of a roster with `revision >= 1` (`Roster::canonical`). A different domain, not the
/// same one with more fields in it: a v1 signature can never be replayed as a v2 one.
pub const ROSTER_DOMAIN_V2: &str = "mesh-roster-v2";
/// The largest level a roster may use. 0 is the top of the fleet; the ladder is small by design so
/// that a number cannot quietly mean something the operator did not intend.
pub const MAX_LEVEL: u8 = 9;
/// Addresses per node. A node with more than a handful is a node whose operator should be told to
/// write them down in the order that matters.
pub const MAX_ADDRESSES: usize = 8;
/// How far in the future a roster may be issued before it is refused as a clock problem.
pub const FUTURE_SKEW_SECONDS: u64 = 300;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RosterError(pub String);

impl std::fmt::Display for RosterError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for RosterError {}

fn bad<T>(why: impl Into<String>) -> Result<T, RosterError> {
    Err(RosterError(why.into()))
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RosterNode {
    pub node_id: String,
    pub public_key: String,
    pub name: String,
    pub level: u8,
    #[serde(default)]
    pub addresses: Vec<String>,
    /// Unix seconds the operator removed this node; `0` means valid. A revoked node is refused as a
    /// caller and as a target, so a stolen key cannot be used even for a call it initiates.
    #[serde(default)]
    pub revoked_at: u64,
}

impl RosterNode {
    pub fn is_revoked(&self, now_s: u64) -> bool {
        self.revoked_at != 0 && self.revoked_at <= now_s
    }

    /// How cheap this address is to try, for the attempt order: a private or link-local address is
    /// one LAN round trip, a public one is the open internet. Lower is tried first.
    pub fn address_rank(address: &str) -> u8 {
        let host = address.rsplit_once(':').map(|(host, _)| host).unwrap_or(address);
        let host = host.trim_matches(['[', ']']).to_ascii_lowercase();
        if host == "localhost"
            || host.starts_with("127.")
            || host.starts_with("10.")
            || host.starts_with("192.168.")
            || host.starts_with("169.254.")
            || host.starts_with("fe80:")
            || host == "::1"
        {
            return 0;
        }
        if let Some(rest) = host.strip_prefix("172.") {
            if let Some(second) = rest.split('.').next().and_then(|part| part.parse::<u8>().ok()) {
                if (16..=31).contains(&second) {
                    return 0;
                }
            }
        }
        if host.starts_with("fc") || host.starts_with("fd") {
            // fc00::/7 — unique local addresses, still the same LAN.
            return 0;
        }
        1
    }

    pub fn address_class(address: &str) -> &'static str {
        if RosterNode::address_rank(address) == 0 {
            "private"
        } else {
            "public"
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Roster {
    pub version: u32,
    pub fleet: String,
    pub issued_at: u64,
    /// `0` means "no expiry". An expiring roster is what makes a revoked key eventually useless even
    /// if the operator forgets to revoke it in a fresh copy.
    #[serde(default)]
    pub expires_at: u64,
    pub nodes: Vec<RosterNode>,
    /// A **monotonic** revision of the fleet roster (`docs/MESH.md` §1): every `revoke`, `rotate` and
    /// re-sign advances it, and a node that holds revision *n* refuses any roster that says less.
    ///
    /// `0` is the legacy value and means "this document predates revisions": it parses, verifies and
    /// behaves exactly as it did before this field existed, because a fleet that cannot be re-signed by
    /// its operator is a fleet locked out by an upgrade. A roster with `revision >= 1` is signed over the
    /// v2 canonical bytes, which are the v1 bytes with the domain string and the two new fields in front,
    /// so a revision cannot be rolled back by deleting a JSON field.
    #[serde(default)]
    pub revision: u32,
    /// The chain hash of the roster this one replaces (`Roster::chain_hash`), empty for the first
    /// revision of a fleet. It is what makes a fork visible: `revoke`, `rotate` and the node's own roster
    /// reader can name the document a change was built on.
    #[serde(default)]
    pub prev_hash: String,
    #[serde(default)]
    pub signature: String,
}

/// Who signs a roster.
///
/// Two implementations, and they are the two places an operator's fleet key may live: a node key file
/// (`Identity`) and the vault (`wa fleet sign --key vault:<name>`, where the seed is opened for one
/// signature and never exported). A node's own call path never signs a roster.
pub trait RosterSigner {
    fn public_key(&self) -> String;
    fn sign_message(&mut self, message: &str) -> Result<String, String>;
}

impl RosterSigner for Identity {
    fn public_key(&self) -> String {
        self.public_key.clone()
    }

    fn sign_message(&mut self, message: &str) -> Result<String, String> {
        Ok(self.sign(message))
    }
}

impl Roster {
    pub fn parse(text: &str) -> Result<Roster, RosterError> {
        let roster: Roster = serde_json::from_str(text)
            .map_err(|error| RosterError(format!("not a valid roster: {error}")))?;
        roster.validate()?;
        Ok(roster)
    }

    pub fn from_file(path: impl AsRef<Path>) -> Result<Roster, RosterError> {
        let path = path.as_ref();
        let text = std::fs::read_to_string(path)
            .map_err(|error| RosterError(format!("{}: {error}", path.display())))?;
        Roster::parse(&text)
    }

    /// Shape checks that do not need the signing key. The signature check is [`Roster::verify`].
    pub fn validate(&self) -> Result<(), RosterError> {
        if self.version != ROSTER_SCHEMA {
            return bad(format!(
                "version {} (this build speaks {ROSTER_SCHEMA})",
                self.version
            ));
        }
        if self.fleet.trim().is_empty() {
            return bad("fleet must not be empty");
        }
        if self.fleet.chars().any(|c| c.is_control()) || self.fleet.len() > 64 {
            return bad("fleet must be short text without control characters");
        }
        // A chain hash is either absent (the first revision) or exactly one sha256 in hex, and only a
        // revisioned roster can have a predecessor.
        if !self.prev_hash.is_empty() {
            check_hex("prev_hash", &self.prev_hash, 64)?;
            if self.revision == 0 {
                return bad("prev_hash requires a revision (a legacy roster has no predecessor)");
            }
        }
        let mut seen = std::collections::BTreeSet::new();
        for node in &self.nodes {
            check_hex("nodes.node_id", &node.node_id, 32)?;
            check_hex("nodes.public_key", &node.public_key, 64)?;
            match derive_node_id(&node.public_key) {
                Some(derived) if derived == node.node_id => {}
                _ => return bad(format!("node_id_mismatch:{}", node.name)),
            }
            if node.name.trim().is_empty() || node.name.len() > 64 {
                return bad("nodes.name must be 1..=64 bytes");
            }
            if node.name.chars().any(|c| c.is_control()) {
                return bad("nodes.name must not contain control characters");
            }
            if node.level > MAX_LEVEL {
                return bad(format!(
                    "level_out_of_range:{} (0..={MAX_LEVEL})",
                    node.name
                ));
            }
            if node.addresses.len() > MAX_ADDRESSES {
                return bad(format!("too_many_addresses:{}", node.name));
            }
            for address in &node.addresses {
                check_address(address)?;
            }
            if !seen.insert(node.node_id.clone()) {
                return bad(format!("duplicate_node:{}", node.node_id));
            }
        }
        Ok(())
    }

    /// The exact bytes the operator signs.
    ///
    /// Two formats, and which one is used is the `revision`: field order is the struct's, so the same
    /// roster always produces the same bytes and a signature cannot be made to verify against a
    /// reordering. `revision == 0` is the legacy v1 document (`docs/MESH.md` §1), byte for byte what it
    /// was, so every roster already pinned on a node keeps verifying. From revision 1 the domain string
    /// and the revision/prev_hash pair are inside the signature, which is what makes a rollback more than
    /// deleting a JSON field.
    pub fn canonical(&self) -> String {
        let nodes = serde_json::to_string(&self.nodes)
            .unwrap_or_else(|_| "[]".to_string());
        if self.revision == 0 {
            return format!(
                "{ROSTER_DOMAIN}|{}|{}|{}|{{\"nodes\":{nodes}}}",
                self.fleet, self.issued_at, self.expires_at
            );
        }
        format!(
            "{ROSTER_DOMAIN_V2}|{}|{}|{}|{}|{}|{{\"nodes\":{nodes}}}",
            self.fleet, self.issued_at, self.expires_at, self.revision, self.prev_hash
        )
    }

    /// The hash a successor roster names in its `prev_hash`: sha256 over the canonical bytes *and* the
    /// signature, so two rosters with the same nodes but different signatures (a fork signed by two keys)
    /// have different chain hashes. Not truncated like `fingerprint`: this one is compared, not read by a
    /// person.
    pub fn chain_hash(&self) -> String {
        sha256_hex(&format!("mesh-roster-chain-v1|{}|{}", self.canonical(), self.signature))
    }

    /// The roster's own anti-rollback rule: refuse a document that is older than `current`, and refuse a
    /// *fork* at the same revision.
    ///
    /// This is what a node applies when it is handed a roster (a push, a relayed document, a file on
    /// disk). A lower revision is `roster_rolled_back`; the same revision with different bytes is
    /// `roster_fork`. An untouched copy of what the node already holds is `Ok`: reinstalling the same
    /// signed document is not a change.
    pub fn refuse_if_not_newer(&self, current: &Roster) -> Result<(), RosterError> {
        if self.revision < current.revision {
            return bad(format!(
                "roster_rolled_back:{}<{}",
                self.revision, current.revision
            ));
        }
        if self.revision == current.revision && self.signature != current.signature {
            return bad(format!("roster_fork:{}", self.revision));
        }
        Ok(())
    }

    /// Sign in place with the fleet key. The caller is the operator's tool, not a node's own view of
    /// itself: nothing in the running node calls this.
    pub fn sign(&mut self, fleet_key: &Identity) {
        self.signature = fleet_key.sign(&self.canonical());
    }

    /// Sign in place with any signer: the operator's node key, or the fleet key held in the open vault
    /// (`wa fleet sign --key vault:<name>`, docs/MESH.md §1). `fleetkey` is the only caller.
    pub fn sign_with(&mut self, signer: &mut dyn RosterSigner) -> Result<(), RosterError> {
        match signer.sign_message(&self.canonical()) {
            Ok(signature) => {
                self.signature = signature;
                Ok(())
            }
            Err(reason) => bad(reason),
        }
    }

    /// Verify against the operator's fleet public key, then the time window, then the node ids.
    ///
    /// Order matters for what the operator is told: a tampered roster is `bad_signature`, an expired
    /// one `roster_expired`, and only a roster that is authentically the operator's is checked for
    /// internal consistency.
    pub fn verify(&self, fleet_public_key: &str, now_s: u64) -> Result<(), RosterError> {
        if fleet_public_key.trim().is_empty() {
            return bad("roster_key_missing");
        }
        check_hex("mesh.roster_key", fleet_public_key, 64)?;
        if !verify(fleet_public_key, &self.canonical(), &self.signature) {
            return bad("roster_unverified:bad_signature");
        }
        if self.issued_at > now_s.saturating_add(FUTURE_SKEW_SECONDS) {
            return bad("roster_not_yet_valid");
        }
        if self.expires_at != 0 && now_s >= self.expires_at {
            return bad("roster_expired");
        }
        self.validate()?;
        Ok(())
    }

    /// A node by id, or by name when the selector is not an id. Names are for a person typing
    /// `wa call <name> …`; what authorizes anything is the id that comes back.
    pub fn node(&self, selector: &str) -> Option<&RosterNode> {
        if let Some(node) = self.nodes.iter().find(|node| node.node_id == selector) {
            return Some(node);
        }
        self.nodes
            .iter()
            .find(|node| node.name.eq_ignore_ascii_case(selector))
    }

    pub fn level_of(&self, node_id: &str) -> Option<u8> {
        self.nodes.iter().find(|node| node.node_id == node_id).map(|node| node.level)
    }

    pub fn names(&self) -> Vec<String> {
        self.nodes.iter().map(|node| format!("{}:{}", node.name, node.level)).collect()
    }

    /// The fingerprint an operator can compare between two nodes without copying the whole file.
    pub fn fingerprint(&self) -> String {
        sha256_hex(&self.canonical())[..16].to_string()
    }

    /// The roster's own view of a node id: the level and key the rest of the mesh must use, and
    /// `None` when this node is not in the fleet at all.
    pub fn level_and_key(&self, node_id: &str) -> Option<(u8, String)> {
        self.nodes
            .iter()
            .find(|node| node.node_id == node_id)
            .map(|node| (node.level, node.public_key.clone()))
    }
}

fn check_hex(where_: &str, text: &str, length: usize) -> Result<(), RosterError> {
    if text.len() != length {
        return bad(format!("{where_}:expected_{length}_hex_characters"));
    }
    if text.chars().any(|c| !c.is_ascii_hexdigit()) || unhex(text).is_none() {
        return bad(format!("{where_}:not_hex"));
    }
    Ok(())
}

fn check_address(address: &str) -> Result<(), RosterError> {
    let trimmed = address.trim();
    if trimmed.is_empty() || trimmed.len() > 253 {
        return bad(format!("bad_address:{address}"));
    }
    if trimmed.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return bad(format!("bad_address:{address}"));
    }
    let Some((host, port)) = trimmed.rsplit_once(':') else {
        return bad(format!("bad_address:{address} (expected host:port)"));
    };
    if host.is_empty() || port.is_empty() {
        return bad(format!("bad_address:{address} (expected host:port)"));
    }
    match port.parse::<u16>() {
        Ok(0) | Err(_) => bad(format!("bad_address:{address} (port must be 1..=65535)")),
        Ok(_) => Ok(()),
    }
}

/// The unsigned material of a new roster, so the operator's tool writes one place and not two.
pub struct Draft {
    pub fleet: String,
    pub issued_at: u64,
    pub expires_at: u64,
    pub nodes: Vec<RosterNode>,
}

impl Draft {
    /// A draft signs as a **legacy** document (`revision: 0`) unless the caller says otherwise, which is
    /// what keeps `wa fleet sign` over a fresh template byte-identical to what it wrote before revisions
    /// existed. A revisioned roster is produced by re-signing a signed one (`fleetkey::sign_with_signer`)
    /// or by `wa fleet revoke`/`rotate`.
    pub fn sign(self, fleet_key: &Identity) -> Roster {
        self.sign_revision(fleet_key, 0, String::new())
    }

    pub fn sign_revision(mut self, fleet_key: &Identity, revision: u32, prev_hash: String) -> Roster {
        let mut roster = Roster {
            version: ROSTER_SCHEMA,
            fleet: std::mem::take(&mut self.fleet),
            issued_at: self.issued_at,
            expires_at: self.expires_at,
            nodes: std::mem::take(&mut self.nodes),
            revision,
            prev_hash,
            signature: String::new(),
        };
        roster.sign(fleet_key);
        roster
    }
}

pub fn node_id_preview(node_id: &str) -> &str {
    &node_id[..node_id.len().min(8)]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::{fleet_key, node};

    fn signed_roster() -> (Identity, Roster) {
        let fleet = fleet_key();
        let roster = Draft {
            fleet: "ohana".into(),
            issued_at: 1_762_000_000,
            expires_at: 1_793_536_000,
            nodes: vec![
                node("laptop", 0, &["192.168.1.10:8891"]),
                node("oracle", 1, &["147.15.64.233:8891"]),
                node("guest", 2, &[]),
            ],
        }
        .sign(&fleet);
        (fleet, roster)
    }

    #[test]
    fn a_signed_roster_verifies_and_says_its_levels() {
        let (fleet, roster) = signed_roster();
        roster.verify(&fleet.public_key, 1_762_000_100).unwrap();
        assert_eq!(roster.level_of(&roster.nodes[1].node_id), Some(1));
        assert_eq!(roster.node("oracle").unwrap().level, 1);
        assert_eq!(roster.node(&roster.nodes[2].node_id).unwrap().name, "guest");
        assert!(roster.node("nobody").is_none());
    }

    #[test]
    fn every_meaningful_tamper_is_refused() {
        let (fleet, roster) = signed_roster();
        let now = 1_762_000_100;

        let mut tampered = roster.clone();
        tampered.nodes[1].level = 0; // "oracle" promotes itself to the top
        assert_eq!(
            tampered.verify(&fleet.public_key, now).unwrap_err().0,
            "roster_unverified:bad_signature"
        );

        let mut tampered = roster.clone();
        tampered.nodes[0].addresses = vec!["10.0.0.9:8891".into()];
        assert!(tampered.verify(&fleet.public_key, now).is_err());

        let mut tampered = roster.clone();
        tampered.nodes[1].public_key = fleet.public_key.clone();
        assert!(tampered.verify(&fleet.public_key, now).is_err());

        // Someone else's key signs: the operator's key is the anchor, not any key.
        let impostor = fleet_key();
        let mut tampered = roster.clone();
        tampered.sign(&impostor);
        assert_eq!(
            tampered.verify(&fleet.public_key, now).unwrap_err().0,
            "roster_unverified:bad_signature"
        );
        assert_eq!(tampered.verify("", now).unwrap_err().0, "roster_key_missing");
    }

    #[test]
    fn the_window_and_the_consistency_checks_are_separate_answers() {
        let (fleet, roster) = signed_roster();
        assert_eq!(
            roster.verify(&fleet.public_key, 1_793_536_000).unwrap_err().0,
            "roster_expired"
        );
        assert_eq!(
            roster.verify(&fleet.public_key, 1_700_000_000).unwrap_err().0,
            "roster_not_yet_valid"
        );
        // A hand-written roster (never signed) is refused before it is looked at.
        let mut unsigned = roster.clone();
        unsigned.signature = String::new();
        assert!(unsigned.verify(&fleet.public_key, 1_762_000_100).is_err());
    }

    #[test]
    fn the_shape_checks_refuse_a_typo_rather_than_reading_it_as_weaker() {
        let (fleet, _) = signed_roster();
        let base = Draft {
            fleet: "f".into(),
            issued_at: 1_762_000_000,
            expires_at: 0,
            nodes: vec![node("a", 0, &["127.0.0.1:8891"])],
        }
        .sign(&fleet);
        assert!(base.verify(&fleet.public_key, 1_762_000_100).is_ok());

        let mut too_deep = base.clone();
        too_deep.nodes[0].level = MAX_LEVEL + 1;
        too_deep.sign(&fleet);
        assert!(too_deep.verify(&fleet.public_key, 1_762_000_100).unwrap_err().0.starts_with("level_out_of_range"));

        let mut wrong_id = base.clone();
        wrong_id.nodes[0].node_id = fleet.node_id.clone();
        wrong_id.sign(&fleet);
        assert!(wrong_id
            .verify(&fleet.public_key, 1_762_000_100)
            .unwrap_err()
            .0
            .starts_with("node_id_mismatch"));

        let mut duplicate = base.clone();
        let again = duplicate.nodes[0].clone();
        duplicate.nodes.push(again);
        duplicate.sign(&fleet);
        assert!(duplicate
            .verify(&fleet.public_key, 1_762_000_100)
            .unwrap_err()
            .0
            .starts_with("duplicate_node"));

        let mut bad_address = base.clone();
        bad_address.nodes[0].addresses = vec!["192.168.1.10".into()];
        bad_address.sign(&fleet);
        assert!(bad_address
            .verify(&fleet.public_key, 1_762_000_100)
            .unwrap_err()
            .0
            .starts_with("bad_address"));

        // Unknown fields are a parse error, not a default: "level" misspelt must not read as 0.
        let text = serde_json::to_string(&base).unwrap().replace("\"level\":0", "\"lvl\":0");
        assert!(Roster::parse(&text).is_err());
        assert!(Roster::parse("{}").is_err());
        assert!(Roster::parse("not json").is_err());
    }

    #[test]
    fn addresses_are_tried_cheapest_first_and_a_lan_address_is_named_private() {
        assert_eq!(RosterNode::address_rank("192.168.1.10:8891"), 0);
        assert_eq!(RosterNode::address_rank("172.20.0.2:1"), 0);
        assert_eq!(RosterNode::address_rank("172.32.0.2:1"), 1);
        assert_eq!(RosterNode::address_rank("147.15.64.233:8891"), 1);
        assert_eq!(RosterNode::address_rank("laptop.example.net:8891"), 1);
        assert_eq!(RosterNode::address_class("10.1.2.3:9"), "private");
        assert_eq!(RosterNode::address_class("8.8.8.8:9"), "public");
    }

    #[test]
    fn a_revoked_node_is_revoked_on_both_sides_of_a_call() {
        let (fleet, mut roster) = signed_roster();
        roster.nodes[2].revoked_at = 1_762_000_050;
        roster.sign(&fleet);
        roster.verify(&fleet.public_key, 1_762_000_100).unwrap();
        assert!(roster.nodes[2].is_revoked(1_762_000_100));
        assert!(!roster.nodes[2].is_revoked(1_762_000_000));
        assert!(!roster.nodes[0].is_revoked(1_762_000_100));
    }
}
