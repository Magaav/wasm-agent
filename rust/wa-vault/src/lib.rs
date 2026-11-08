//! The vault, as a component: `docs/VAULT.md` is the design, this is the engine.
//!
//! One document of entries, each value sealed with XChaCha20-Poly1305 under per-entry AAD
//! `name|version` (XChaCha20-Poly1305 in the kernel keystore, or the same cipher under a local key when
//! the vault is opened without the kernel). What this crate guarantees, in the order it matters:
//!
//! 1. **A value leaves through exactly two doors.** `use_by_ref` answers only when the actor is the
//!    kernel; `reveal` answers only with a `vault.reveal` grant naming this actor and this entry.
//!    Everything else - `list`, audit, rotation, errors, the document on disk - carries names,
//!    versions and reasons, never a value.
//! 2. **An ed25519 seed is never exported.** `sign` opens it for the length of one signature and drops
//!    it ([`Vault::sign`] is the only operation that can even reach it) and `public_key` answers the
//!    public half, which is not a secret.
//! 3. **Rotation keeps the previous version for a window, then destroys it.** The old ciphertext stays
//!    readable until `retire_at` (default 7 days) so a client pinned to the old generation still works
//!    through the change; after it, `purge_expired` deletes the material rather than hiding it.
//! 4. **Every operation appends one hash-chained audit line.** `audit verify` recomputes the chain from
//!    the file, so an edited, reordered or truncated line is a failure an operator can see.
//! 5. **No JSON crosses the seam.** The document format here is this crate's business; the component
//!    interface is the typed records of `wit/vault/vault.wit`.
//!
//! The store is bytes in and bytes out ([`Store`]), because the component keeps the same document in
//! its own kv namespace and the CLI keeps it in 0600 files. There is no other difference between them:
//! the CLI is this engine, not a second reader of the file.
use std::collections::BTreeMap;
use zeroize::Zeroizing;

pub mod audit;
pub mod cli;
pub mod hex;
pub mod migrate;
pub mod policy;
pub mod store;
#[cfg(test)]
mod tests;

pub use audit::{AuditRecord, ChainError};
pub use policy::Policy;
pub use store::{FileStore, Store};

pub use wa_keystore::Sealer;

/// Schema of the document on disk. A reader refuses anything else: a vault is not a place for
/// best-effort parsing.
pub const DOC_SCHEMA: u32 = 1;
/// Domain string of the entry AAD. In the AAD, so a ciphertext cannot be replayed from another
/// format that happens to use the same seal.
const ENTRY_DOMAIN: &str = "vault-entry-v1";
/// The default window a rotated-out version stays readable for.
pub const DEFAULT_ROTATION_WINDOW_S: i64 = 7 * 24 * 60 * 60;
/// The longest name a entry may have. Bounded so the audit line and the AAD stay small.
pub const MAX_NAME: usize = 64;

/// A refusal. The message is a stable reason word (plus, where useful, the name), never a value:
/// errors reach a component's log and an operator's terminal, and neither is a place for a secret.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VaultError(pub String);

impl VaultError {
    pub fn reason(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for VaultError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for VaultError {}

impl From<VaultError> for String {
    /// The CLI reports a refusal by its reason word, and a reason word is the whole message a vault
    /// error carries: this is the one conversion that keeps value material out of a `Result<_, String>`
    /// by construction.
    fn from(error: VaultError) -> Self {
        error.0
    }
}

pub(crate) fn bad<T>(reason: impl Into<String>) -> Result<T> {
    Err(VaultError(reason.into()))
}

type Result<T> = std::result::Result<T, VaultError>;

/// Who is asking. Kernel and operator are the two privileged callers; a component is every guest.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Actor {
    /// The node's own code: the only actor `use_by_ref` answers.
    Kernel,
    /// The operator's terminal (`wa vault ...`).
    Operator(String),
    /// A component, by name as the manifest declares it.
    Component(String),
}

impl Actor {
    pub fn id(&self) -> String {
        match self {
            Actor::Kernel => "kernel".to_string(),
            Actor::Operator(name) => format!("operator:{name}"),
            Actor::Component(name) => format!("component:{name}"),
        }
    }

    pub fn is_kernel(&self) -> bool {
        matches!(self, Actor::Kernel)
    }

    /// May create, rotate and delete entries.
    pub fn can_admin(&self) -> bool {
        matches!(self, Actor::Kernel | Actor::Operator(_))
    }

    pub fn parse(text: &str) -> Self {
        match text {
            "kernel" => Actor::Kernel,
            other => match other.split_once(':') {
                Some(("operator", name)) => Actor::Operator(name.to_string()),
                Some(("component", name)) => Actor::Component(name.to_string()),
                _ => Actor::Operator(other.to_string()),
            },
        }
    }
}

/// What an entry holds, which decides what may be done with it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// An ordinary secret: a provider key, a token. Usable by reference, revealable with a grant.
    Secret,
    /// A 32-byte ed25519 seed. `sign` only; the seed itself is never exported.
    Ed25519,
}

impl Kind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Kind::Secret => "secret",
            Kind::Ed25519 => "ed25519",
        }
    }
}

/// Everything about an entry that is not a secret. This is what `list` answers and what an
/// operator reads; there is no field here a `secret` could ride in.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Meta {
    pub kind: Kind,
    /// The live version. Every rotation increments it; a version is never reused.
    pub version: u32,
    /// Unix seconds the entry was created.
    pub created: i64,
    /// Unix seconds of the last rotation (`== created` when never rotated).
    pub rotated_at: i64,
    /// Who created the entry (`kernel` or `operator:<name>`).
    pub owner: String,
    /// Actor ids allowed to `sign` this entry. Empty means the owner and the kernel only.
    pub allowed: Vec<String>,
}

impl Meta {
    pub fn may_sign(&self, actor: &Actor) -> bool {
        match actor {
            Actor::Kernel => true,
            // Every operator session is the same person at the same terminal (the CLI runs as the
            // user); the name in the audit line says which session, not which privilege. A component
            // is the one actor that has to be named.
            Actor::Operator(_) if self.owner.starts_with("operator:") => true,
            other => self.allowed.iter().any(|id| id == &other.id() || id == "*"),
        }
    }
}

/// One sealed version of an entry.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SealedVersion {
    pub version: u32,
    /// Sealed bytes, hex. The ciphertext is not a secret *key*, but it is still stored as hex so the
    /// document stays one text file the operator can back up.
    pub sealed: String,
    /// Unix seconds this version became non-live (`0` while it is the live one).
    pub retired_at: i64,
    /// Unix seconds after which this version is destroyed (`0` while live).
    pub destroy_at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Entry {
    pub meta: Meta,
    /// Oldest first, live version last. Bounded by the rotation window (a rotation purges first).
    pub versions: Vec<SealedVersion>,
}

impl Entry {
    fn live(&self) -> Result<&SealedVersion> {
        self.versions
            .iter()
            .find(|sealed| sealed.version == self.meta.version)
            .ok_or_else(|| VaultError(format!("vault_corrupt:{}", self.meta.version)))
    }
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Doc {
    pub schema: u32,
    pub entries: BTreeMap<String, Entry>,
    /// The last line's hash, so a *truncated* audit log is detected as well as an edited one.
    pub audit_head: String,
    pub audit_seq: u64,
}

impl Default for Doc {
    fn default() -> Self {
        Doc {
            schema: DOC_SCHEMA,
            entries: BTreeMap::new(),
            audit_head: audit::GENESIS.to_string(),
            audit_seq: 0,
        }
    }
}

/// Unix seconds. Injected so the rotation window can be tested without sleeping for a week.
pub trait Clock: Send + Sync {
    fn now(&self) -> i64;
}

pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_secs() as i64)
            .unwrap_or(0)
    }
}

pub struct VaultOptions {
    pub policy: Policy,
    pub clock: Box<dyn Clock>,
    pub rotation_window_s: i64,
    pub owner: String,
}

impl Default for VaultOptions {
    fn default() -> Self {
        VaultOptions {
            policy: Policy::default(),
            clock: Box::new(SystemClock),
            rotation_window_s: DEFAULT_ROTATION_WINDOW_S,
            owner: "kernel".to_string(),
        }
    }
}

pub struct Vault {
    sealer: Box<dyn Sealer>,
    store: Box<dyn Store>,
    doc: Doc,
    policy: Policy,
    clock: Box<dyn Clock>,
    rotation_window_s: i64,
    owner: String,
}

impl Vault {
    /// Open the document from the store, or start an empty one. A document from another schema is a
    /// refusal, not a migration: guessing is how a vault loses entries.
    pub fn open(
        sealer: Box<dyn Sealer>,
        store: Box<dyn Store>,
        options: VaultOptions,
    ) -> Result<Self> {
        let doc = match store.load().map_err(|error| VaultError(format!("vault_store:{error}")))? {
            Some(bytes) => {
                let doc: Doc = serde_json::from_slice(&bytes)
                    .map_err(|_| VaultError("vault_document_unreadable".to_string()))?;
                if doc.schema != DOC_SCHEMA {
                    return bad(format!("vault_document_schema:{}", doc.schema));
                }
                doc
            }
            None => Doc::default(),
        };
        Ok(Vault {
            sealer,
            store,
            doc,
            policy: options.policy,
            clock: options.clock,
            rotation_window_s: options.rotation_window_s,
            owner: options.owner,
        })
    }

    /// The rotation window this vault was opened with, in seconds.
    pub fn rotation_window(&self) -> i64 {
        self.rotation_window_s
    }

    pub fn policy(&self) -> &Policy {
        &self.policy
    }

    pub fn set_policy(&mut self, policy: Policy) {
        self.policy = policy;
    }

    pub fn names(&self) -> Vec<String> {
        self.doc.entries.keys().cloned().collect()
    }

    pub fn get_meta(&self, name: &str) -> Option<&Meta> {
        self.doc.entries.get(name).map(|entry| &entry.meta)
    }

    /// `list`: names and metadata only. There is no variant of this that carries a value.
    pub fn list(&self) -> Vec<(String, Meta)> {
        self.doc
            .entries
            .iter()
            .map(|(name, entry)| (name.clone(), entry.meta.clone()))
            .collect()
    }

    /// Create an entry, or replace the value of an existing one at the next version (which is what
    /// `wa vault set` does to a name that exists: it is a rotation, not an overwrite of the same
    /// ciphertext).
    pub fn set(&mut self, name: &str, kind: Kind, value: &[u8], actor: &Actor) -> Result<Meta> {
        self.authorize_admin(actor)?;
        self.validate_name(name)?;
        self.check_value(kind, value)?;
        match kind {
            Kind::Ed25519 => self.insert_ed25519(name, value, actor),
            Kind::Secret => {
                if value.is_empty() {
                    return bad("vault_value_empty");
                }
                self.insert("set", name, kind, value, actor)
            }
        }
    }

    fn insert(&mut self, op: &str, name: &str, kind: Kind, value: &[u8], actor: &Actor) -> Result<Meta> {
        let now = self.clock.now();
        let existing = self.doc.entries.get(name).cloned();
        let (version, created, allowed) = match &existing {
            Some(entry) => (entry.meta.version + 1, entry.meta.created, entry.meta.allowed.clone()),
            None => (1, now, Vec::new()),
        };
        let sealed = self.seal(name, version, kind, value)?;
        let mut versions = existing.clone().map(|entry| entry.versions).unwrap_or_default();
        retire_versions(&mut versions, version, now, self.rotation_window_s);
        versions.push(SealedVersion { version, sealed, retired_at: 0, destroy_at: 0 });
        let meta = Meta {
            kind,
            version,
            created,
            rotated_at: now,
            // The kernel's own writes carry the configured owner name (`kernel` unless a host says
            // otherwise); an operator's write carries the session, so two terminals are distinguishable
            // in the audit without either of them being a privilege.
            owner: if existing.is_some() {
                self.doc.entries[name].meta.owner.clone()
            } else if actor.is_kernel() {
                self.owner.clone()
            } else {
                actor.id()
            },
            allowed,
        };
        self.doc.entries.insert(name.to_string(), Entry { meta: meta.clone(), versions });
        self.commit(op, actor, name, version, "ok")?;
        Ok(meta)
    }

    /// Import an ed25519 seed. `bytes` is a 32-byte seed (`import-ed25519`).
    pub fn import_ed25519(&mut self, name: &str, seed: &[u8], actor: &Actor) -> Result<Meta> {
        if seed.len() != 32 {
            return bad("vault_seed_length");
        }
        let public = ed25519_public(seed)?;
        let meta = self.set(name, Kind::Ed25519, seed, actor)?;
        self.commit("import-ed25519", actor, name, meta.version, &format!("ok:{}", hex::encode(&public)))?;
        Ok(meta)
    }

    fn insert_ed25519(&mut self, name: &str, seed: &[u8], actor: &Actor) -> Result<Meta> {
        self.insert("set", name, Kind::Ed25519, seed, actor)
    }

    /// `sign`: the only operation that reaches an ed25519 seed, and it returns a signature.
    pub fn sign(&mut self, name: &str, actor: &Actor, message: &[u8]) -> Result<Vec<u8>> {
        let entry = match self.doc.entries.get(name) {
            Some(entry) => entry.clone(),
            None => {
                self.commit("sign", actor, name, 0, "refused:unknown_entry")?;
                return bad("vault_unknown_entry");
            }
        };
        if entry.meta.kind != Kind::Ed25519 {
            self.commit("sign", actor, name, entry.meta.version, "refused:kind_mismatch")?;
            return bad("vault_kind_mismatch");
        }
        if !entry.meta.may_sign(actor) {
            self.commit("sign", actor, name, entry.meta.version, "refused:not_allowed")?;
            return bad("vault_not_allowed");
        }
        let seed = match self.unseal(name, &entry) {
            Ok(seed) => seed,
            Err(error) => {
                let reason = format!("refused:{}", error.reason());
                self.commit("sign", actor, name, entry.meta.version, &reason)?;
                return Err(error);
            }
        };
        let signature = ring::signature::Ed25519KeyPair::from_seed_unchecked(seed.as_slice())
            .map_err(|_| VaultError("vault_seed_invalid".to_string()))?
            .sign(message)
            .as_ref()
            .to_vec();
        self.commit("sign", actor, name, entry.meta.version, "ok")?;
        Ok(signature)
    }

    /// The public half of an ed25519 entry. Public data, so no grant is involved.
    pub fn public_key(&self, name: &str) -> Result<Vec<u8>> {
        let entry = self.doc.entries.get(name).ok_or_else(|| VaultError("vault_unknown_entry".to_string()))?;
        if entry.meta.kind != Kind::Ed25519 {
            return bad("vault_kind_mismatch");
        }
        let seed = self.unseal(name, entry)?;
        ed25519_public(seed.as_slice())
    }

    /// `use_by_ref`: the kernel asks for the value to inject it into an outbound credential header.
    /// No other actor is answered, whatever the policy says - there is no grant that opens this door.
    pub fn use_by_ref(&mut self, name: &str, actor: &Actor) -> Result<Zeroizing<Vec<u8>>> {
        if !actor.is_kernel() {
            self.commit("use_by_ref", actor, name, 0, "refused:kernel_only")?;
            return bad("vault_kernel_only");
        }
        let entry = match self.doc.entries.get(name) {
            Some(entry) => entry.clone(),
            None => {
                self.commit("use_by_ref", actor, name, 0, "refused:unknown_entry")?;
                return bad("vault_unknown_entry");
            }
        };
        let value = self.unseal(name, &entry);
        let (result, answer) = match value {
            Ok(value) => ("ok".to_string(), Ok(value)),
            Err(error) => (format!("refused:{}", error.reason()), Err(error)),
        };
        self.commit("use_by_ref", actor, name, entry.meta.version, &result)?;
        answer
    }

    /// `reveal`: a component gets a value only with a `vault.reveal` grant naming exactly this actor
    /// and this entry. The kernel and the operator's own terminal are the vault's owners; a component
    /// never is.
    pub fn reveal(&mut self, name: &str, actor: &Actor) -> Result<Zeroizing<Vec<u8>>> {
        // A component's only door is the grant, and the grant names exactly this actor and entry.
        // Kernel and operator are the vault's owners, so neither needs one - and neither can be
        // widened by a component's grant.
        if let Actor::Component(_) = actor {
            if !self.policy.allows_reveal(actor, name) {
                self.commit("reveal", actor, name, 0, "refused:reveal_not_granted")?;
                return bad("vault_reveal_not_granted");
            }
        } else if !actor.can_admin() {
            self.commit("reveal", actor, name, 0, "refused:not_allowed")?;
            return bad("vault_not_allowed");
        }
        let entry = match self.doc.entries.get(name) {
            Some(entry) => entry.clone(),
            None => {
                self.commit("reveal", actor, name, 0, "refused:unknown_entry")?;
                return bad("vault_unknown_entry");
            }
        };
        let value = self.unseal(name, &entry);
        let (result, answer) = match value {
            Ok(value) => ("ok".to_string(), Ok(value)),
            Err(error) => (format!("refused:{}", error.reason()), Err(error)),
        };
        self.commit("reveal", actor, name, entry.meta.version, &result)?;
        answer
    }

    /// `rotate`: a new live version, the previous one kept (readable by a client that pinned it) until
    /// the window ends. With `new_value` absent the value is re-sealed under a new nonce and version -
    /// the same secret, a new generation.
    pub fn rotate(&mut self, name: &str, actor: &Actor, new_value: Option<&[u8]>) -> Result<Meta> {
        self.authorize_admin(actor)?;
        let entry = self.doc.entries.get(name).cloned().ok_or_else(|| VaultError("vault_unknown_entry".to_string()))?;
        let value = match new_value {
            Some(value) => {
                self.check_value(entry.meta.kind, value)?;
                value.to_vec()
            }
            None => match self.unseal(name, &entry) {
                Ok(value) => value.to_vec(),
                Err(error) => {
                    self.commit("rotate", actor, name, entry.meta.version, &format!("refused:{}", error.reason()))?;
                    return Err(error);
                }
            },
        };
        let meta = self.insert("rotate", name, entry.meta.kind, &value, actor)?;
        Ok(meta)
    }

    pub fn delete(&mut self, name: &str, actor: &Actor) -> Result<()> {
        self.authorize_admin(actor)?;
        let removed = self.doc.entries.remove(name);
        match removed {
            Some(entry) => self.commit("delete", actor, name, entry.meta.version, "ok"),
            None => {
                self.commit("delete", actor, name, 0, "refused:unknown_entry")?;
                bad("vault_unknown_entry")
            }
        }
    }

    /// Destroy every retired version whose window has ended. Called at open and by `rotate`, so a node
    /// that rotates but never runs a purge still destroys old material on the next start.
    pub fn purge_expired(&mut self, now: i64) -> Result<Vec<(String, u32)>> {
        let mut destroyed = Vec::new();
        let names: Vec<String> = self.doc.entries.keys().cloned().collect();
        for name in names {
            let Some(entry) = self.doc.entries.get_mut(&name) else { continue };
            let mut kept = Vec::with_capacity(entry.versions.len());
            for version in entry.versions.drain(..) {
                if version.version != entry.meta.version && version.destroy_at > 0 && version.destroy_at <= now {
                    destroyed.push((name.clone(), version.version));
                } else {
                    kept.push(version);
                }
            }
            entry.versions = kept;
        }
        for (name, version) in &destroyed {
            self.commit("destroy", &Actor::Kernel, name, *version, "ok")?;
        }
        Ok(destroyed)
    }

    /// Whether a rotated-out version is still readable. Used by `wa vault show` and by the tests that
    /// pin the window; there is no path here that returns the value.
    pub fn has_version(&self, name: &str, version: u32) -> bool {
        self.doc
            .entries
            .get(name)
            .map(|entry| entry.versions.iter().any(|sealed| sealed.version == version))
            .unwrap_or(false)
    }

    /// The audit chain, verified from the stored lines (not from this process's memory).
    pub fn verify_audit(&self) -> std::result::Result<usize, ChainError> {
        let log = self.store.audit().map_err(|error| ChainError(format!("vault_store:{error}")))?;
        let lines: Vec<&str> = log.lines().filter(|line| !line.trim().is_empty()).collect();
        let records = audit::parse(&lines)?;
        audit::verify(&records, &self.doc.audit_head)
    }

    pub fn audit_lines(&self) -> Vec<String> {
        self.store
            .audit()
            .map(|log| log.lines().map(str::to_string).collect())
            .unwrap_or_default()
    }

    /// Whether the live value of an entry is exactly `bytes`. Used by the migration ("already there,
    /// same value" is `kept`), and it answers a bool: nothing is returned that could be printed.
    pub fn value_matches(&self, name: &str, bytes: &[u8]) -> bool {
        let Some(entry) = self.doc.entries.get(name) else { return false };
        match self.unseal(name, entry) {
            Ok(opened) => opened.as_slice() == bytes,
            Err(_) => false,
        }
    }

    fn seal(&self, name: &str, version: u32, kind: Kind, value: &[u8]) -> Result<String> {
        let context = format!("{ENTRY_DOMAIN}|{}|{name}|{version}", kind.as_str());
        let sealed = self
            .sealer
            .seal(&context, value)
            .map_err(|error| VaultError(format!("vault_seal:{}", error.reason())))?;
        Ok(hex::encode(&sealed))
    }

    fn unseal(&self, name: &str, entry: &Entry) -> Result<Zeroizing<Vec<u8>>> {
        let version = entry.live()?;
        let sealed = hex::decode(&version.sealed).ok_or_else(|| VaultError("vault_corrupt".to_string()))?;
        let context = format!("{ENTRY_DOMAIN}|{}|{name}|{}", entry.meta.kind.as_str(), entry.meta.version);
        let opened = self
            .sealer
            .open(&context, &sealed)
            .map_err(|error| VaultError(format!("vault_open:{}", error.reason())))?;
        // The version in the AAD is the live one; the seal call above used exactly that, so a document
        // whose `versions` and `meta.version` disagree cannot open (and `live()` already refused).
        if opened.is_empty() {
            return bad("vault_corrupt");
        }
        Ok(opened)
    }

    fn authorize_admin(&self, actor: &Actor) -> Result<()> {
        if actor.can_admin() {
            Ok(())
        } else {
            bad("vault_kernel_only")
        }
    }

    fn validate_name(&self, name: &str) -> Result<()> {
        if name.is_empty() || name.len() > MAX_NAME {
            return bad("vault_name_invalid");
        }
        if !name.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'/')) {
            return bad("vault_name_invalid");
        }
        Ok(())
    }

    fn check_value(&self, kind: Kind, value: &[u8]) -> Result<()> {
        match kind {
            Kind::Ed25519 => {
                if value.len() != 32 {
                    return bad("vault_seed_length");
                }
                ed25519_public(value)?;
                Ok(())
            }
            Kind::Secret => Ok(()),
        }
    }

    /// Append one audit line and persist the document atomically. The document is written *after* the
    /// line, so a crash between them leaves an audit line with no state change - which is the safe
    /// direction (an operator sees the attempt; nothing was half-written).
    fn commit(&mut self, op: &str, actor: &Actor, name: &str, version: u32, result: &str) -> Result<()> {
        let now = self.clock.now();
        let seq = self.doc.audit_seq + 1;
        let record = AuditRecord::next(&self.doc.audit_head, seq, now, &actor.id(), op, name, version, result);
        let line = serde_json::to_string(&record).map_err(|_| VaultError("vault_audit_encode".to_string()))?;
        self.store
            .append(&line)
            .map_err(|error| VaultError(format!("vault_store:{error}")))?;
        self.doc.audit_head = record.hash.clone();
        self.doc.audit_seq = seq;
        let bytes = serde_json::to_vec(&self.doc).map_err(|_| VaultError("vault_document_encode".to_string()))?;
        self.store
            .save(&bytes)
            .map_err(|error| VaultError(format!("vault_store:{error}")))?;
        Ok(())
    }
}

fn ed25519_public(seed: &[u8]) -> Result<Vec<u8>> {
    let keypair = ring::signature::Ed25519KeyPair::from_seed_unchecked(seed)
        .map_err(|_| VaultError("vault_seed_invalid".to_string()))?;
    use ring::signature::KeyPair;
    Ok(keypair.public_key().as_ref().to_vec())
}

/// Retire the live version (if any) with the window computed from `now`, then drop versions past their
/// destruction time so one rotate cannot leave unbounded history behind.
fn retire_versions(versions: &mut Vec<SealedVersion>, live: u32, now: i64, window_s: i64) {
    for version in versions.iter_mut() {
        if version.version != live && version.retired_at == 0 {
            version.retired_at = now;
            version.destroy_at = now + window_s.max(0);
        }
    }
    versions.retain(|version| version.version == live || version.destroy_at == 0 || version.destroy_at > now);
}
