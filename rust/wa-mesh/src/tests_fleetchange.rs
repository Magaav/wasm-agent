//! The roster's revision/chain rules, and `wa fleet revoke|rotate|anchor` with the fleet key in the
//! vault (`docs/MESH.md` §1/§7, `docs/VAULT.md`).
//!
//! Everything runs in a temp directory: no node, no network, no real vault. The vault is a real one
//! (a real keystore, a real sealed document) with a passphrase, in a directory the test owns.
use crate::fleetchange;
use crate::fleetkey::sign_with_signer;
use crate::identity::Identity;
use crate::roster::Roster;
use crate::testkit;

fn write_roster(path: &std::path::Path, roster: &Roster) {
    let mut text = serde_json::to_string_pretty(roster).expect("json");
    text.push('\n');
    std::fs::write(path, text).expect("write roster");
}

fn signed_roster_files(tag: &str) -> (Identity, Roster, std::path::PathBuf) {
    let fleet = testkit::fleet_key();
    let lap = testkit::node("laptop", 0, &["192.168.1.10:8891"]);
    let node = testkit::node("wasm_the_first", 1, &["147.15.64.233:8891"]);
    let mut roster = testkit::roster_of(&fleet, vec![lap, node]);
    // Revisioned, as `wa fleet sign` produces after the first re-sign.
    roster.revision = 1;
    roster.issued_at = 1_760_000_000;
    roster.prev_hash = String::new();
    roster.sign(&fleet);
    let dir = testkit::temp_dir(tag);
    let path = dir.join("roster.json");
    write_roster(&path, &roster);
    (fleet, roster, path)
}

#[test]
fn a_legacy_roster_keeps_its_exact_signed_bytes() {
    // `revision: 0` is the v1 document every pinned roster already is: same domain, same field order,
    // same bytes. If this changes, every node in a live fleet stops verifying on upgrade.
    let fleet = testkit::fleet_key();
    let roster = testkit::roster_of(&fleet, vec![testkit::node("laptop", 0, &["127.0.0.1:8891"])]);
    assert_eq!(roster.revision, 0);
    assert!(roster.canonical().starts_with("mesh-roster-v1|ohana|"));
    assert_eq!(
        roster.canonical(),
        format!(
            "mesh-roster-v1|{fleet_name}|{}|{}|{{\"nodes\":{}}}",
            roster.issued_at,
            roster.expires_at,
            serde_json::to_string(&roster.nodes).expect("nodes"),
            fleet_name = roster.fleet
        )
    );
    roster.verify(&fleet.public_key, roster.issued_at).expect("verifies as before");
}

#[test]
fn a_revisioned_roster_is_signed_over_the_v2_bytes_and_the_chain_hash_covers_the_signature() {
    let fleet = testkit::fleet_key();
    let mut roster = testkit::roster_of(&fleet, vec![testkit::node("laptop", 0, &["127.0.0.1:8891"])]);
    roster.revision = 1;
    roster.sign(&fleet);
    assert!(roster.canonical().starts_with("mesh-roster-v2|ohana|"));
    roster.verify(&fleet.public_key, roster.issued_at).expect("verifies");
    let hash = roster.chain_hash();
    assert_eq!(hash.len(), 64);
    // A different signature is a different chain hash even with identical nodes: a fork is visible.
    let mut fork = roster.clone();
    fork.signature = "00".repeat(64);
    assert_ne!(fork.chain_hash(), hash);
    // And a v1 signature can never be replayed as a v2 one: the domain string is in the bytes.
    let mut replay = roster.clone();
    replay.revision = 0;
    replay.verify(&fleet.public_key, roster.issued_at).expect_err("revision is signed");
}

#[test]
fn a_node_refuses_a_lower_revision_and_a_fork_at_the_same_one() {
    let fleet = testkit::fleet_key();
    let mut older = testkit::roster_of(&fleet, vec![testkit::node("laptop", 0, &["127.0.0.1:8891"])]);
    older.revision = 2;
    older.sign(&fleet);
    let mut newer = older.clone();
    newer.revision = 3;
    newer.prev_hash = older.chain_hash();
    newer.sign(&fleet);

    newer.refuse_if_not_newer(&older).expect("a newer revision is accepted");
    older.refuse_if_not_newer(&newer).expect_err("a lower revision is refused");
    let rolled_back = older.refuse_if_not_newer(&newer).unwrap_err().0;
    assert_eq!(rolled_back, "roster_rolled_back:2<3");

    // Same revision, different bytes: a fork, and named as one.
    let mut fork = older.clone();
    fork.issued_at += 1;
    fork.sign(&fleet);
    assert_eq!(fork.refuse_if_not_newer(&older).unwrap_err().0, "roster_fork:2");
    // Reinstalling exactly what the node holds is not a change.
    older.refuse_if_not_newer(&older.clone()).expect("a copy is not a fork");
}

#[test]
fn a_roster_with_a_prev_hash_but_no_revision_is_refused() {
    let fleet = testkit::fleet_key();
    let mut roster = testkit::roster_of(&fleet, vec![testkit::node("laptop", 0, &["127.0.0.1:8891"])]);
    roster.prev_hash = "ab".repeat(32);
    let error = roster.validate().expect_err("a legacy roster cannot have a predecessor");
    assert!(error.0.contains("prev_hash requires a revision"), "{error}");
}

#[test]
fn revoke_sets_revoked_at_chains_the_previous_document_and_re_signs() {
    let (fleet, original, path) = signed_roster_files("revoke");
    let fleet_public = fleet.public_key.clone();
    let mut signer = fleet;
    let changed = fleetchange::revoke(&path, "wasm_the_first", &mut signer, None, 1_760_000_500)
        .expect("revoke");
    assert_eq!(changed.revision, 2);
    assert_eq!(changed.prev_hash, original.chain_hash());
    assert_eq!(changed.revoked, vec!["wasm_the_first".to_string()]);
    // The re-signed document verifies under the same fleet key and says the node is gone.
    let text = std::fs::read_to_string(&changed.path).expect("signed roster");
    let roster = Roster::parse(&text).expect("parses");
    roster.verify(&fleet_public, 1_760_000_500).expect("verifies");
    let node = roster.node("wasm_the_first").expect("node");
    assert_eq!(node.revoked_at, 1_760_000_500);
    assert!(node.is_revoked(1_760_000_500));
    // The template it was built from is untouched.
    assert_eq!(std::fs::read_to_string(&path).expect("template"), {
        let mut text = serde_json::to_string_pretty(&original).expect("json");
        text.push('\n');
        text
    });
}

#[test]
fn revoke_of_a_node_that_is_not_in_the_roster_is_a_named_refusal() {
    let (fleet, _original, path) = signed_roster_files("revoke-missing");
    let mut signer = fleet;
    let error = fleetchange::revoke(&path, "nobody", &mut signer, None, 1_760_000_500).unwrap_err();
    assert_eq!(error, "roster_missing_target: nobody");
}

#[test]
fn rotate_re_signs_under_the_new_key_and_prints_the_anchor_the_old_key_must_sign() {
    let (old_fleet, _original, path) = signed_roster_files("rotate");
    let old_public = old_fleet.public_key.clone();
    let new_fleet = testkit::identity("new-fleet");
    let mut new_signer = new_fleet;
    let rotated = fleetchange::rotate(&path, &mut new_signer, None, 1_760_000_900).expect("rotate");
    assert_eq!(rotated.revision, 2);
    let text = std::fs::read_to_string(&rotated.path).expect("signed roster");
    let roster = Roster::parse(&text).expect("parses");
    roster.verify(&rotated.public_key, 1_760_000_900).expect("the new key verifies it");
    roster
        .verify(&old_public, 1_760_000_900)
        .expect_err("the old key must not verify the rotated roster");
    assert_eq!(
        rotated.anchor_message,
        format!("mesh-anchor-v1|{}|{}", rotated.public_key, rotated.fingerprint)
    );
    // The anchor signature is made by the OLD key, and it verifies under it: that is what lets a node
    // that pins the old key accept the new one (`--replace-key`, docs/MESH.md §7).
    let mut old_signer = old_fleet;
    let signature = fleetchange::anchor(&rotated.path, &mut old_signer, &rotated.public_key).expect("anchor");
    let key = ring::signature::UnparsedPublicKey::new(
        &ring::signature::ED25519,
        crate::identity::unhex(&old_public).expect("hex"),
    );
    key.verify(
        rotated.anchor_message.as_bytes(),
        &crate::identity::unhex(&signature).expect("hex"),
    )
    .expect("the anchor verifies under the key the node pins now");
}

#[test]
fn a_re_sign_of_a_signed_roster_advances_the_revision_and_chains_it() {
    let (fleet, original, path) = signed_roster_files("resign");
    let mut signer = fleet;
    let signed = sign_with_signer(&path, &mut signer, None, Some(90), 1_760_001_000, None).expect("sign");
    assert!(signed.replaced_signature);
    assert_eq!(signed.revision, 2);
    assert_eq!(signed.prev_hash, original.chain_hash());
    // An explicit --revision wins, and a fresh template keeps revision 0 (legacy) as before.
    let signed = sign_with_signer(&path, &mut signer, None, None, 1_760_001_100, Some(7)).expect("sign");
    assert_eq!(signed.revision, 7);
}

/// A real vault, a real keystore, a real sealed document: the fleet key is an ed25519 entry and the
/// signer this module builds is the one `wa fleet sign --key vault:fleet` uses.
fn vault_with_fleet_key(tag: &str) -> (std::path::PathBuf, String) {
    let dir = testkit::temp_dir(tag);
    let mut vault = fleetchange::open_vault(&dir, None, None).expect("vault");
    vault
        .import_ed25519("fleet", &[9u8; 32], &wa_vault::Actor::Operator("test".to_string()))
        .expect("import");
    let public = crate::identity::hex(&vault.public_key("fleet").expect("public"));
    (dir, public)
}

#[test]
fn the_fleet_key_signs_from_the_vault_and_the_seed_is_never_exported() {
    // `WASM_AGENT_VAULT_PASSPHRASE` is how the sealed fallback opens without a terminal. This is the only
    // test in the binary that touches the variable, so nothing races with it; the vault lives in a temp
    // directory and never at a node home.
    std::env::set_var("WASM_AGENT_VAULT_PASSPHRASE", "fleet-test-passphrase");
    let (dir, public) = vault_with_fleet_key("vault-sign");
    let mut signer =
        fleetchange::signer_for("vault:fleet", Some(&dir), None).expect("the vault signer opens");
    assert_eq!(signer.public_key(), public);

    let roster_path = dir.join("roster.json");
    let template = testkit::roster_of(
        &testkit::fleet_key(),
        vec![testkit::node("laptop", 0, &["127.0.0.1:8891"])],
    );
    write_roster(&roster_path, &template);
    let signed = sign_with_signer(&roster_path, signer.as_mut(), None, None, 1_760_000_000, None)
        .expect("sign from the vault");
    let roster =
        Roster::parse(&std::fs::read_to_string(&signed.path).expect("roster")).expect("parses");
    roster.verify(&public, 1_760_000_000).expect("the vault's public key verifies the roster");
    assert_eq!(signed.public_key, public);

    // A key that was never imported is a named refusal, not a panic or a wrong signature.
    let missing = fleetchange::signer_for("vault:absent", Some(&dir), None).err().expect("refused");
    assert!(missing.contains("vault_unknown_entry"), "{missing}");

    // The vault's own audit log records the signature and never the seed.
    let log = std::fs::read_to_string(dir.join(wa_vault::store::AUDIT_FILE)).expect("audit");
    assert!(log.contains("\"op\":\"sign\""), "the signature is an audited vault operation");
    assert!(!log.contains(&"09".repeat(32)), "the seed is not in the audit log");
    let doc = std::fs::read_to_string(dir.join(wa_vault::store::DOC_FILE)).expect("document");
    assert!(!doc.contains(&"09".repeat(32)));
    std::env::remove_var("WASM_AGENT_VAULT_PASSPHRASE");
}

#[test]
fn a_vault_key_with_no_name_is_refused_before_any_vault_is_opened() {
    let dir = testkit::temp_dir("vault-no-name");
    let error = fleetchange::VaultSigner::open(&dir, "", None).err().expect("refused");
    assert_eq!(error, "vault_key_name_missing");
}
