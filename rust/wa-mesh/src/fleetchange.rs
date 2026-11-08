//! `wa fleet revoke`, `wa fleet rotate` and `wa fleet anchor`: the operator's side of a *change* to the
//! fleet, with the fleet key kept in the vault.
//!
//! `docs/MESH.md` §1 and §7 describe the roster and `push-roster`; §9 keeps the open questions. What
//! lives here is the part the vault added, and the shape of it is one idea:
//!
//! > a change to the fleet is a **new revision** of one signed document, chained to the document it
//! > replaces, signed by a key the operator holds in the vault.
//!
//! So `revoke` edits the roster (a node's `revoked_at`), `rotate` re-signs it under a **new** fleet key,
//! and both bump `revision` and set `prev_hash` to the predecessor's chain hash. A node refuses a lower
//! revision (`Roster::refuse_if_not_newer`), which is the anti-rollback half; the chain hash is the
//! fork-visible half.
//!
//! What these functions deliberately do **not** do is talk to a node. Pushing a roster is
//! `wa fleet push-roster` (already tested, `docs/MESH.md` §7) and it is a separate, deliberate act per
//! node: a `revoke` that also reached out to the network could not be reviewed before it happened, and
//! a test of it would need real peers. Each command prints the exact next commands instead, so the
//! operator's shell history is the record of what was pushed where.
//!
//! Nothing here prints a key, and the vault is opened read-write only for the one signature.
use crate::identity::{self, Identity};
use crate::roster::{Roster, RosterSigner};
use serde_json::json;
use std::path::{Path, PathBuf};

/// How an operator names a signing key: a node key file, or `vault:<entry>` for the fleet key the vault
/// holds (`wa vault import-ed25519 fleet --from <path>` first, docs/VAULT.md).
pub const VAULT_PREFIX: &str = "vault:";

/// A signer backed by the open vault. The seed is opened for the length of one signature inside the
/// vault engine and never leaves it: this type holds a name, not a key.
pub struct VaultSigner {
    vault: wa_vault::Vault,
    name: String,
}

impl VaultSigner {
    /// `dir` is the vault directory (`--vault-dir`, else `WASM_AGENT_VAULT_DIR`). The policy file is the
    /// node's, so a `vault.reveal` grant cannot be invented by this command; signing needs no grant.
    pub fn open(dir: &Path, name: &str, policy_path: Option<&Path>) -> Result<VaultSigner, String> {
        if name.trim().is_empty() {
            return Err("vault_key_name_missing".to_string());
        }
        let vault = open_vault(dir, policy_path, None)?;
        // Refuse before anything is signed: a name that is not an ed25519 entry can only fail later,
        // and a caller that got this far is about to produce a fleet document.
        match vault.get_meta(name) {
            Some(meta) if meta.kind == wa_vault::Kind::Ed25519 => {}
            Some(_) => return Err("vault_kind_mismatch".to_string()),
            None => return Err("vault_unknown_entry".to_string()),
        }
        Ok(VaultSigner { vault, name: name.to_string() })
    }

    pub fn name(&self) -> &str {
        &self.name
    }
}

impl RosterSigner for VaultSigner {
    fn public_key(&self) -> String {
        match self.vault.public_key(&self.name) {
            Ok(public) => identity::hex(&public),
            Err(error) => format!("unavailable:{}", error.reason()),
        }
    }

    fn sign_message(&mut self, message: &str) -> Result<String, String> {
        // The operator's own vault entry is the fleet key; the vault's audit line records the actor of
        // the *signature*, which is what an operator reading `wa vault audit tail` needs to see.
        let signature = self
            .vault
            .sign(&self.name, &wa_vault::Actor::Operator("fleet".to_string()), message.as_bytes())
            .map_err(|error| error.reason().to_string())?;
        Ok(identity::hex(&signature))
    }
}

/// A signer from `--key <path|vault:name>`. The vault directory is `--vault-dir`, else
/// `WASM_AGENT_VAULT_DIR`; a vault key with no directory is a refusal rather than a guess.
pub fn signer_for(
    key: &str,
    vault_dir: Option<&Path>,
    policy: Option<&Path>,
) -> Result<Box<dyn RosterSigner>, String> {
    if let Some(name) = key.strip_prefix(VAULT_PREFIX) {
        let dir = vault_dir
            .map(Path::to_path_buf)
            .or_else(|| std::env::var_os(wa_vault::cli::DIR_ENV).map(PathBuf::from))
            .ok_or_else(|| {
                format!("vault_dir_unset: --key {key} needs --vault-dir or {}", wa_vault::cli::DIR_ENV)
            })?;
        return Ok(Box::new(VaultSigner::open(&dir, name, policy)?));
    }
    let identity = Identity::open(Path::new(key))
        .map_err(|error| format!("fleet_key_unusable: {}: {error}", Path::new(key).display()))?;
    Ok(Box::new(identity))
}


/// Open the vault in `dir`: the same construction the `wa vault` CLI uses, so a signature made here is
/// made by the same engine an operator's `wa vault sign` would use.
///
/// `passphrase` is the operator's own, and only for a host whose protection falls back to the sealed
/// file (`wa_keystore::Protection::PassphraseFile`); with `None` the process environment is the only
/// source, which is what a node and the CLI use.
pub fn open_vault(
    dir: &Path,
    policy_path: Option<&Path>,
    passphrase: Option<&str>,
) -> Result<wa_vault::Vault, String> {
    let policy = match policy_path {
        Some(path) => {
            let text = std::fs::read_to_string(path)
                .map_err(|error| format!("policy_read: {}: {error}", path.display()))?;
            wa_vault::Policy::from_policy_json(&text).map_err(|error| error.to_string())?
        }
        None => wa_vault::Policy::default(),
    };
    let options = match passphrase {
        Some(passphrase) => wa_keystore::Options::new(dir).with_passphrase(passphrase),
        None => wa_keystore::Options::from_env(dir),
    };
    let mut keystore = wa_keystore::Keystore::open(&options)
        .map_err(|error| error.reason().to_string())?;
    keystore.ensure_root().map_err(|error| error.reason().to_string())?;
    let keystore = std::sync::Arc::new(keystore);
    wa_vault::Vault::open(
        Box::new(keystore.for_namespace("vault")),
        Box::new(wa_vault::FileStore::new(dir)),
        wa_vault::VaultOptions {
            policy,
            owner: "operator:fleet".to_string(),
            ..wa_vault::VaultOptions::default()
        },
    )
    .map_err(|error| error.to_string())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Changed {
    pub path: PathBuf,
    pub fleet: String,
    pub revision: u32,
    pub prev_hash: String,
    pub fingerprint: String,
    pub signature: String,
    pub public_key: String,
    /// The nodes the document now says are revoked (`revoke` only).
    pub revoked: Vec<String>,
}

/// Revoke one node (`--at` defaults to now) and re-sign as the next revision.
pub fn revoke(
    roster_path: &Path,
    selector: &str,
    signer: &mut dyn RosterSigner,
    out: Option<&Path>,
    now_s: u64,
) -> Result<Changed, String> {
    let mut roster = read(roster_path)?;
    let node_id = roster
        .node(selector)
        .ok_or_else(|| format!("roster_missing_target: {selector}"))?
        .node_id
        .clone();
    let prev_hash = roster.chain_hash();
    let revision = next_revision(&roster);
    {
        let node = roster
            .nodes
            .iter_mut()
            .find(|node| node.node_id == node_id)
            .expect("the node was found above");
        if node.revoked_at == 0 {
            node.revoked_at = now_s;
        }
    }
    roster.revision = revision;
    roster.prev_hash = prev_hash.clone();
    roster.issued_at = now_s;
    roster.sign_with(signer).map_err(|error| format!("roster_invalid: {}", error.0))?;
    let path = write(&roster, roster_path, out)?;
    Ok(Changed {
        path,
        fleet: roster.fleet.clone(),
        revision,
        prev_hash,
        fingerprint: roster.fingerprint(),
        signature: roster.signature.clone(),
        public_key: signer.public_key(),
        revoked: roster
            .nodes
            .iter()
            .filter(|node| node.revoked_at != 0)
            .map(|node| node.name.clone())
            .collect(),
    })
}

/// Re-sign the fleet under a **new** key (`signer`), as the next revision chained to the old document.
///
/// The old key is not touched and not needed to write this document: the anchor signature that lets a
/// node re-pin from the old key to the new one (`docs/MESH.md` §7, `--replace-key`) is [`anchor`], and
/// the returned `anchor_message` is the string the **old** key must sign.
pub fn rotate(
    roster_path: &Path,
    signer: &mut dyn RosterSigner,
    out: Option<&Path>,
    now_s: u64,
) -> Result<Rotated, String> {
    let mut roster = read(roster_path)?;
    let prev_hash = roster.chain_hash();
    let revision = next_revision(&roster);
    roster.revision = revision;
    roster.prev_hash = prev_hash.clone();
    roster.issued_at = now_s;
    roster.sign_with(signer).map_err(|error| format!("roster_invalid: {}", error.0))?;
    let public_key = signer.public_key();
    let fingerprint = roster.fingerprint();
    let message = anchor_message(&public_key, &fingerprint);
    let path = write(&roster, roster_path, out)?;
    Ok(Rotated {
        path,
        fleet: roster.fleet.clone(),
        revision,
        prev_hash,
        fingerprint,
        signature: roster.signature.clone(),
        public_key,
        anchor_message: message,
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rotated {
    pub path: PathBuf,
    pub fleet: String,
    pub revision: u32,
    pub prev_hash: String,
    pub fingerprint: String,
    pub signature: String,
    /// The new fleet public key: what every node must pin after the rotation.
    pub public_key: String,
    /// `mesh-anchor-v1|<new key>|<fingerprint>`: sign this with the **old** key to get `--replace-key`.
    pub anchor_message: String,
}

/// The bytes a node checks for a re-anchor (`docs/MESH.md` §7).
pub fn anchor_message(new_public_key: &str, roster_fingerprint: &str) -> String {
    format!("mesh-anchor-v1|{}|{}", new_public_key.trim().to_ascii_lowercase(), roster_fingerprint)
}

/// Produce the `--replace-key` signature with the key a node pins **now**.
pub fn anchor(
    roster_path: &Path,
    old_signer: &mut dyn RosterSigner,
    new_public_key: &str,
) -> Result<String, String> {
    let roster = read(roster_path)?;
    let message = anchor_message(new_public_key, &roster.fingerprint());
    old_signer.sign_message(&message)
}

fn next_revision(roster: &Roster) -> u32 {
    // A legacy roster (revision 0) becomes revision 1; anything newer moves on by one. Saturating, so a
    // roster at the top of the range keeps verifying instead of wrapping to 0 (which would read as
    // "legacy" and drop the anti-rollback rule).
    if roster.revision == 0 {
        1
    } else {
        roster.revision.saturating_add(1)
    }
}

fn read(path: &Path) -> Result<Roster, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|error| format!("roster_unreadable: {}: {error}", path.display()))?;
    Roster::parse(&text).map_err(|error| format!("roster_invalid: {}", error.0))
}

fn write(roster: &Roster, original: &Path, out: Option<&Path>) -> Result<PathBuf, String> {
    let target = out.map(Path::to_path_buf).unwrap_or_else(|| crate::fleetkey::signed_path(original));
    let mut document = serde_json::to_string_pretty(roster).map_err(|error| error.to_string())?;
    document.push('\n');
    crate::fleetkey::write_atomic(&target, document.as_bytes())?;
    Ok(target)
}

/// The JSON each command prints, so the CLI's shape is testable without a terminal.
pub fn json_changed(changed: &Changed) -> serde_json::Value {
    json!({
        "ok": true,
        "path": changed.path.to_string_lossy(),
        "fleet": changed.fleet,
        "revision": changed.revision,
        "prev_hash": changed.prev_hash,
        "fingerprint": changed.fingerprint,
        "signature": changed.signature,
        "public_key": changed.public_key,
        "revoked": changed.revoked,
    })
}

pub fn json_rotated(rotated: &Rotated) -> serde_json::Value {
    json!({
        "ok": true,
        "path": rotated.path.to_string_lossy(),
        "fleet": rotated.fleet,
        "revision": rotated.revision,
        "prev_hash": rotated.prev_hash,
        "fingerprint": rotated.fingerprint,
        "signature": rotated.signature,
        "public_key": rotated.public_key,
        "anchor_message": rotated.anchor_message,
        "next": [
            "wa fleet anchor <signed roster> --key vault:<old> --new <public_key>",
            "wa fleet push-roster <node> --replace-key <signature>",
            "wa vault delete <old>    # only after every node confirms the new key",
        ],
    })
}
