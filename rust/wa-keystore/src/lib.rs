//! `wa:kernel/keystore` — the key that never leaves the kernel process.
//!
//! `docs/VAULT.md` has the design; this is the code. One root data key (32 bytes) is created once per
//! vault directory and stored **wrapped** by the strongest protection this host has:
//!
//! | host | protection | where the wrapping key lives |
//! | --- | --- | --- |
//! | Windows | `dpapi` | `CryptProtectData`, **user** scope: the blob only unwraps as this user on this machine |
//! | Linux | `keyring` | the session/user kernel keyring (`add_key`/`keyctl`), never a file |
//! | either, fallback | `passphrase` | a 0600 file sealed with an XChaCha20-Poly1305 key derived by Argon2id from an operator passphrase |
//!
//! TPM 2.0 is deliberately not here: no `tpm2`/`tss-esapi` crate builds offline on this toolchain, and
//! a half-wired TPM that silently fell back to DPAPI would be worse than saying "later" (`REPORT.md`,
//! open questions).
//!
//! What a component gets is **not** a key. [`Keystore::seal`] and [`Keystore::open`] take a namespace
//! (the component's own, bound by the host, never a parameter the guest chooses freely) and a context
//! string (the AAD: for the vault an entry's `name|version`), and answer an opaque blob. The per
//! namespace subkey is HKDF-SHA256 of the root key, so two components' blobs are not openable under
//! each other's namespace even if both names are the same. That is the whole point: "the root key
//! never leaves the kernel" is only true if the interface never hands one out, and this one cannot.
//!
//! Failures are named and carry no secret: a wrong passphrase is `passphrase_refused`, a corrupt blob
//! is `sealed_blob_corrupt`, and neither message includes the blob, the context or a length beyond
//! "sealed".
use std::path::{Path, PathBuf};
use ring::rand::SecureRandom;
use zeroize::Zeroizing;

mod seal;

#[cfg(target_os = "linux")]
mod keyring;
#[cfg(windows)]
mod dpapi;

/// File the wrapped root key lives in, under the keystore directory.
pub const ROOT_FILE: &str = "root-key.wrap";
/// Domain string mixed into every subkey derivation, so a key sealed here cannot be confused with a
/// key sealed by a future format under the same root.
const KDF_DOMAIN: &[u8] = b"wa-keystore-v1";

/// The wrapped-root file's size says which protection wrote it. The root is always 32 bytes, so a sealed
/// blob is `version || nonce[24] || ciphertext+tag[48]` (`seal.rs`) = 73 bytes, and the passphrase file
/// is that with its own 16-byte Argon2id salt in front = 89 bytes.
///
/// This is a *reading* rule, not a format change: both protections have written exactly these sizes
/// since the file existed, so a vault written by either one opens under this build. It exists because
/// the protection is otherwise recorded nowhere, and choosing it per process from a mutable machine
/// resource (the kernel keyring) made one process read another process's file with the wrong cipher:
/// measured on wa-desktop (13/11), a keyring-wrapped file read on the passphrase path had its version
/// byte taken from the keyring blob's nonce, and the vault answered `sealed_blob_version_unknown` for a
/// file that was perfectly intact.
const SEALED_ROOT_LEN: usize = 1 + 24 + 32 + 16;
const PASSPHRASE_ROOT_LEN: usize = 16 + SEALED_ROOT_LEN;

/// Which protection wraps the root key. This is **not** a secret and is reported in
/// `wa vault status` and in the audit line of every start.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Protection {
    /// Windows DPAPI, user scope.
    Dpapi,
    /// The Linux kernel keyring.
    KernelKeyring,
    /// A 0600 file sealed with an Argon2id-derived key. The fallback, and the only one that needs an
    /// operator passphrase.
    PassphraseFile,
}

impl Protection {
    pub fn as_str(&self) -> &'static str {
        match self {
            Protection::Dpapi => "dpapi",
            Protection::KernelKeyring => "keyring",
            Protection::PassphraseFile => "passphrase",
        }
    }

    /// Which protection wrote this wrapped-root file, or `None` when this host cannot tell from the
    /// bytes. Linux: the two shapes are exact and distinct (see `SEALED_ROOT_LEN`). Windows: a DPAPI
    /// blob has no fixed shape, and a Windows host has no ambiguity to resolve — its default protection
    /// does not depend on machine state, so the chosen protection stands.
    pub fn from_root_file(blob: &[u8]) -> Option<Protection> {
        #[cfg(target_os = "linux")]
        {
            match blob.len() {
                SEALED_ROOT_LEN => Some(Protection::KernelKeyring),
                PASSPHRASE_ROOT_LEN => Some(Protection::PassphraseFile),
                _ => None,
            }
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = blob;
            None
        }
    }

    /// Parse the operator's `WASM_AGENT_VAULT_KEYSTORE` override. An unknown value is a refusal, not a
    /// silent default: a typo must not quietly downgrade the protection.
    pub fn parse(name: &str) -> Result<Self> {
        match name {
            "dpapi" => Ok(Protection::Dpapi),
            "keyring" => Ok(Protection::KernelKeyring),
            "passphrase" | "file" => Ok(Protection::PassphraseFile),
            other => Err(Error::bad(format!("keystore_protection_unknown:{other}"))),
        }
    }
}

#[derive(Clone, Debug)]
pub struct Options {
    /// The keystore directory (the vault's own directory: `<home>/vault`).
    pub dir: PathBuf,
    /// The operator passphrase, when the fallback protection is used. `None` means "not supplied":
    /// the fallback then refuses rather than sealing under an empty key.
    pub passphrase: Option<Zeroizing<String>>,
    /// Force a protection (the tests do; an operator may with `WASM_AGENT_VAULT_KEYSTORE`).
    pub requested: Option<Protection>,
}

impl Options {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Options { dir: dir.into(), passphrase: None, requested: None }
    }

    pub fn with_passphrase(mut self, passphrase: impl Into<String>) -> Self {
        self.passphrase = Some(Zeroizing::new(passphrase.into()));
        self
    }

    pub fn with_protection(mut self, protection: Protection) -> Self {
        self.requested = Some(protection);
        self
    }

    /// The process environment is read **here** and nowhere else, so a test can build `Options`
    /// directly and never has to mutate the environment of the whole test binary.
    pub fn from_env(dir: impl Into<PathBuf>) -> Self {
        let mut options = Options::new(dir);
        if let Ok(name) = std::env::var("WASM_AGENT_VAULT_KEYSTORE") {
            if let Ok(protection) = Protection::parse(name.trim()) {
                options.requested = Some(protection);
            }
        }
        if let Ok(passphrase) = std::env::var("WASM_AGENT_VAULT_PASSPHRASE") {
            if !passphrase.is_empty() {
                options.passphrase = Some(Zeroizing::new(passphrase));
            }
        }
        options
    }
}

/// Is a root key present? Never says what it is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Status {
    pub root: bool,
    pub protection: Protection,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error(pub String);

impl Error {
    fn bad(what: impl Into<String>) -> Self {
        Error(what.into())
    }

    pub fn reason(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

type Result<T> = std::result::Result<T, Error>;

/// The keyless interface the vault engine (and, through the host, a component) talks to.
///
/// The namespace is part of the object, not of the call, so an implementation a component reaches can
/// only ever seal and open its own blobs: there is no argument that widens it.
pub trait Sealer: Send + Sync {
    fn seal(&self, context: &str, plaintext: &[u8]) -> Result<Vec<u8>>;
    fn open(&self, context: &str, sealed: &[u8]) -> Result<Zeroizing<Vec<u8>>>;
}

pub struct Keystore {
    dir: PathBuf,
    protection: Protection,
    passphrase: Option<Zeroizing<String>>,
    /// The root key, unwrapped for the life of this object. Never written, never returned.
    root: Option<Zeroizing<[u8; 32]>>,
    /// Test-only: the keyring this keystore talks to. `Some` in this crate's tests, which point it at a
    /// private keyring they invalidate to get a REAL refusal from the kernel without spending the
    /// machine's key budget; `None` (and absent from every shipping build) means the user's keyring.
    #[cfg(test)]
    ring: Option<i32>,
    /// The one named note this keystore owes an operator, if any: `keystore_keyring_refused:<errno>`
    /// when a refused keyring made it take the passphrase file, `keystore_protection_from_file:<p>` when
    /// the file on disk decided the protection instead of the environment. Printed once by the caller
    /// (`wa vault ...`), never stored and never repeated: a note is a fact about one process's start.
    note: Option<String>,
}

impl Keystore {
    /// Open (or prepare) the keystore. Does not create a root key; [`Keystore::ensure_root`] does.
    pub fn open(options: &Options) -> Result<Self> {
        std::fs::create_dir_all(&options.dir)
            .map_err(|error| Error::bad(format!("keystore_dir: {error}")))?;
        let mut keystore = Keystore {
            dir: options.dir.clone(),
            protection: options.requested.unwrap_or(Protection::PassphraseFile),
            passphrase: options.passphrase.clone(),
            root: None,
            #[cfg(test)]
            ring: None,
            note: None,
        };
        if keystore.root_path().exists() {
            // The FILE says how it was wrapped, and that is the whole rule. Asking the machine instead
            // is what made one process read another process's file with the wrong cipher
            // (`sealed_blob_version_unknown` on an intact file), and it is also what spent the uid's
            // keyring quota on every single `wa vault` command, existing vault or not.
            let blob = std::fs::read(keystore.root_path())
                .map_err(|error| Error::bad(format!("keystore_root_unreadable: {error}")))?;
            let on_disk = Self::protection_for_file(options, &blob)?;
            if let Some(requested) = options.requested {
                if requested != on_disk {
                    keystore.note = Some(format!(
                        "keystore_protection_from_file:{}, so WASM_AGENT_VAULT_KEYSTORE={} is ignored",
                        on_disk.as_str(),
                        requested.as_str()
                    ));
                }
            }
            keystore.protection = on_disk;
            keystore.root = Some(keystore.load_root()?);
        } else {
            let (protection, note) = resolve_protection(options);
            keystore.protection = protection;
            keystore.note = note;
        }
        Ok(keystore)
    }

    /// How a wrapped-root file that already exists must be read. Linux: by its shape, and an unexpected
    /// length is a refusal rather than a guess (a blob written by a protection this machine does not have
    /// is exactly what guessing used to mis-parse). Elsewhere: the requested protection, else the host
    /// default, as before.
    fn protection_for_file(options: &Options, blob: &[u8]) -> Result<Protection> {
        #[cfg(target_os = "linux")]
        {
            let _ = options;
            Protection::from_root_file(blob).ok_or_else(|| Error::bad("keystore_root_corrupt"))
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = blob;
            Ok(options.requested.unwrap_or_else(|| default_protection(&options.dir)))
        }
    }

    /// The one note this keystore owes an operator (`keystore_keyring_refused:edquot`, …), for the
    /// caller to print once. `None` when the protection it took is the one it asked for.
    pub fn note(&self) -> Option<&str> {
        self.note.as_deref()
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn protection(&self) -> Protection {
        self.protection
    }

    pub fn status(&self) -> Status {
        Status { root: self.root_path().exists(), protection: self.protection }
    }

    /// The keyring this keystore reads its wrapping key from: the user's, except in this crate's tests.
    fn keyring(&self) -> i32 {
        #[cfg(test)]
        {
            if let Some(ring) = self.ring {
                return ring;
            }
        }
        keyring::user_keyring()
    }

    /// Test-only: read the wrapping key from `ring` instead of the user's keyring.
    #[cfg(test)]
    fn with_ring(mut self, ring: i32) -> Self {
        self.ring = Some(ring);
        self
    }

    fn root_path(&self) -> PathBuf {
        self.dir.join(ROOT_FILE)
    }

    /// Create the root key if it is absent. Idempotent: an existing root is never replaced, because
    /// replacing it would make every ciphertext already on disk unreadable, silently.
    pub fn ensure_root(&mut self) -> Result<Status> {
        if self.root.is_some() {
            return Ok(self.status());
        }
        let root = generate_root()?;
        let mut note = None;
        let blob = self.wrap_root(&root, &mut note)?;
        if note.is_some() {
            // The wrap fell back to the passphrase file, so what this keystore reports from here on —
            // `status().protection`, the audit line, the next `wa vault status` of a new process that
            // reads the file's shape — has to be what the file actually is.
            self.protection = Protection::PassphraseFile;
            self.note = note;
        }
        write_0600(&self.root_path(), &blob)?;
        self.root = Some(root);
        Ok(self.status())
    }

    /// The root key, for a caller that has to derive something of its own (the kernel's `kv` sealing,
    /// the node identity export). Deliberately crate-visible only: outside this crate there is no way
    /// to obtain a key, only [`Sealer`].
    pub(crate) fn root(&self) -> Result<&Zeroizing<[u8; 32]>> {
        self.root.as_ref().ok_or_else(|| Error::bad("keystore_root_missing"))
    }

    fn load_root(&self) -> Result<Zeroizing<[u8; 32]>> {
        let blob = std::fs::read(self.root_path())
            .map_err(|error| Error::bad(format!("keystore_root_unreadable: {error}")))?;
        let plain = self.unwrap_root(&blob)?;
        if plain.len() != 32 {
            return Err(Error::bad("keystore_root_corrupt"));
        }
        let mut root = Zeroizing::new([0u8; 32]);
        root.copy_from_slice(&plain);
        Ok(root)
    }

    fn wrap_root(&self, root: &[u8; 32], note: &mut Option<String>) -> Result<Vec<u8>> {
        match self.protection {
            Protection::Dpapi => {
                #[cfg(windows)]
                {
                    dpapi::protect(KDF_DOMAIN, root)
                }
                #[cfg(not(windows))]
                {
                    Err(Error::bad("keystore_protection_unavailable:dpapi"))
                }
            }
            Protection::KernelKeyring => {
                #[cfg(target_os = "linux")]
                {
                    // The keyring holds the wrapping key; the file holds the XChaCha blob, so the
                    // root key is never in a file in the clear and never fully in the keyring.
                    match keyring::wrapping_key_in(&self.dir, self.keyring()) {
                        Ok(wrapping) => seal::seal_with(&wrapping, KDF_DOMAIN, root),
                        // A real refusal is not a dead end when a passphrase is configured: the sealed
                        // file is the fallback this keystore exists to take, and it takes it with ONE
                        // named note instead of the hard `keystore_keyring_unavailable` that three
                        // vault rows died with inside the fast path (13/11, the uid's key quota spent).
                        // With no passphrase the answer is exactly what it was: the refusal.
                        Err(refusal) if self.passphrase.is_some() => {
                            *note = Some(format!(
                                "keystore_keyring_refused:{}, using the passphrase file",
                                refusal.name()
                            ));
                            self.passphrase_wrap(root)
                        }
                        Err(refusal) => Err(refusal.into()),
                    }
                }
                #[cfg(not(target_os = "linux"))]
                {
                    let _ = note;
                    Err(Error::bad("keystore_protection_unavailable:keyring"))
                }
            }
            Protection::PassphraseFile => self.passphrase_wrap(root),
        }
    }

    /// The sealed-file half of a wrap: a fresh salt per wrapping, stored in front of the blob so one
    /// passphrase on two machines does not derive one key.
    fn passphrase_wrap(&self, root: &[u8; 32]) -> Result<Vec<u8>> {
        let mut salt = [0u8; 16];
        ring::rand::SystemRandom::new()
            .fill(&mut salt)
            .map_err(|_| Error::bad("keystore_entropy_unavailable"))?;
        let wrapping = self.passphrase_key(&salt)?;
        let sealed = seal::seal_with(&wrapping, KDF_DOMAIN, root)?;
        let mut blob = Vec::with_capacity(salt.len() + sealed.len());
        blob.extend_from_slice(&salt);
        blob.extend_from_slice(&sealed);
        Ok(blob)
    }

    fn unwrap_root(&self, blob: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
        match self.protection {
            Protection::Dpapi => {
                #[cfg(windows)]
                {
                    dpapi::unprotect(KDF_DOMAIN, blob).map(Zeroizing::new)
                }
                #[cfg(not(windows))]
                {
                    let _ = blob;
                    Err(Error::bad("keystore_protection_unavailable:dpapi"))
                }
            }
            Protection::KernelKeyring => {
                #[cfg(target_os = "linux")]
                {
                    // The file says a keyring wrapped it, so the keyring is the only thing that can open
                    // it: a passphrase cannot, and pretending it might would answer
                    // `sealed_blob_version_unknown` about a file that is intact. The refusal is named.
                    let wrapping = keyring::wrapping_key_in(&self.dir, self.keyring())
                        .map_err(Error::from)?;
                    seal::open_with(&wrapping, KDF_DOMAIN, blob)
                }
                #[cfg(not(target_os = "linux"))]
                {
                    let _ = blob;
                    Err(Error::bad("keystore_protection_unavailable:keyring"))
                }
            }
            Protection::PassphraseFile => {
                if blob.len() < 16 {
                    return Err(Error::bad("keystore_root_corrupt"));
                }
                let (salt, sealed) = blob.split_at(16);
                let wrapping = self.passphrase_key(salt)?;
                seal::open_with(&wrapping, KDF_DOMAIN, sealed)
            }
        }
    }

    fn passphrase_key(&self, salt: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
        let passphrase = self
            .passphrase
            .as_ref()
            .filter(|value| !value.is_empty())
            .ok_or_else(|| Error::bad("keystore_passphrase_missing"))?;
        seal::argon2id_key(passphrase.as_bytes(), salt)
    }

    /// The `Sealer` for one namespace: seals and opens blobs under this keystore's root key, derived
    /// for `namespace` only. It owns an `Arc` of the keystore, so a host can hand it to a component for
    /// the life of that component while the keystore itself outlives the call.
    pub fn for_namespace(self: &std::sync::Arc<Self>, namespace: &str) -> crate::NamespacedSealer {
        crate::NamespacedSealer { keystore: std::sync::Arc::clone(self), namespace: namespace.to_string() }
    }

    /// The per-namespace subkey. Never returned outside this crate; `NamespacedSealer` uses it and
    /// drops it before the call returns to a guest.
    fn subkey(&self, namespace: &str) -> Result<Zeroizing<[u8; 32]>> {
        let root = self.root()?;
        let salt = ring::hkdf::Salt::new(ring::hkdf::HKDF_SHA256, KDF_DOMAIN);
        // `extract` looks infallible in `ring`'s API for a fixed-length PRK input (`Salt::extract`
        // cannot fail for SHA-256 with any input length), so the key is derived without an error path.
        let prk = salt.extract(root.as_ref());
        let info = [namespace.as_bytes()];
        let okm = prk.expand(&info, SubkeyLen).map_err(|_| Error::bad("keystore_kdf_failed"))?;
        let mut key = Zeroizing::new([0u8; 32]);
        okm.fill(key.as_mut()).map_err(|_| Error::bad("keystore_kdf_failed"))?;
        Ok(key)
    }
}

/// `ring::hkdf::KeyType` for a fixed 32-byte output. A named type because `expand` is generic over it.
struct SubkeyLen;

impl ring::hkdf::KeyType for SubkeyLen {
    fn len(&self) -> usize {
        32
    }
}

/// The `Sealer` a host binds to one namespace before it hands it to a component.
pub struct NamespacedSealer {
    keystore: std::sync::Arc<Keystore>,
    namespace: String,
}

impl Sealer for NamespacedSealer {
    fn seal(&self, context: &str, plaintext: &[u8]) -> Result<Vec<u8>> {
        let key = self.keystore.subkey(&self.namespace)?;
        seal::seal_with(&key, context.as_bytes(), plaintext)
    }

    fn open(&self, context: &str, sealed: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
        let key = self.keystore.subkey(&self.namespace)?;
        seal::open_with(&key, context.as_bytes(), sealed)
    }
}

fn generate_root() -> Result<Zeroizing<[u8; 32]>> {
    let rng = ring::rand::SystemRandom::new();
    let mut root = Zeroizing::new([0u8; 32]);
    rng.fill(root.as_mut()).map_err(|_| Error::bad("keystore_entropy_unavailable"))?;
    Ok(root)
}

/// The host's default protection, for a host that cannot tell a wrapped-root file's shape (Windows).
#[cfg(not(target_os = "linux"))]
fn default_protection(dir: &Path) -> Protection {
    #[cfg(windows)]
    {
        let _ = dir;
        Protection::Dpapi
    }
    #[cfg(not(windows))]
    {
        // No keyring on this host: the passphrase file is the honest fallback, and `wa vault status`
        // says so.
        let _ = dir;
        Protection::PassphraseFile
    }
}

/// The protection a keystore takes when it has no root key yet (so nothing on disk decides it), and the
/// one note that decision owes an operator.
///
/// A real keyring refusal with a passphrase configured is a downgrade we can take and must name: the
/// sealed file is the protection the vault was designed to fall back to, and the alternative is the hard
/// `keystore_keyring_unavailable` that three vault rows died with inside the fast path (13/11 — the uid's
/// 200-key quota spent by the very rows that ran before them). With no passphrase the answer is exactly
/// what it was before this note existed: the passphrase path, and the `keystore_passphrase_missing`
/// refusal that names what is absent. Never weaker, only louder.
fn resolve_protection(options: &Options) -> (Protection, Option<String>) {
    #[cfg(windows)]
    {
        resolve_protection_with(options, Ok(()))
    }
    #[cfg(not(windows))]
    {
        resolve_protection_with(options, keyring_availability(&options.dir))
    }
}

/// The decision itself, with the keyring's answer as an argument: that is what makes a refusal — EPERM in
/// a container, EDQUOT when the uid's key budget is spent — testable without spending a real one.
fn resolve_protection_with(
    options: &Options,
    keyring: std::result::Result<(), &'static str>,
) -> (Protection, Option<String>) {
    if let Some(requested) = options.requested {
        return (requested, None);
    }
    #[cfg(windows)]
    {
        let _ = keyring;
        (Protection::Dpapi, None)
    }
    #[cfg(not(windows))]
    {
        let passphrase = options.passphrase.as_ref().map(|value| !value.is_empty()).unwrap_or(false);
        match keyring {
            Ok(()) => (Protection::KernelKeyring, None),
            Err(reason) if passphrase => (
                Protection::PassphraseFile,
                Some(format!("keystore_keyring_refused:{reason}, using the passphrase file")),
            ),
            Err(_) => (Protection::PassphraseFile, None),
        }
    }
}

#[cfg(not(windows))]
fn keyring_availability(dir: &Path) -> std::result::Result<(), &'static str> {
    #[cfg(all(target_os = "linux", any(target_arch = "x86_64", target_arch = "aarch64")))]
    {
        keyring::available(dir).map_err(|refusal| refusal.name())
    }
    #[cfg(not(all(target_os = "linux", any(target_arch = "x86_64", target_arch = "aarch64"))))]
    {
        let _ = dir;
        Err("unsupported")
    }
}

/// Refusals from the kernel keyring reach an operator in the words they have always seen, and reach this
/// crate's caller as a value first ([`keyring::Refusal`]) so the keystore can decide to fall back.
#[cfg(target_os = "linux")]
impl From<keyring::Refusal> for Error {
    fn from(refusal: keyring::Refusal) -> Error {
        match refusal.name() {
            // This build has no syscall numbers for this architecture, so there is no keyring here at
            // all: the refusal names the protection, not the keyring.
            "unsupported" => Error::bad("keystore_protection_unavailable:keyring"),
            _ => Error::bad("keystore_keyring_unavailable"),
        }
    }
}

/// 0600 where the host has POSIX modes; on Windows the file inherits the user's profile ACL, which is
/// the same boundary DPAPI already relies on (docs/VAULT.md says so plainly rather than implying more).
fn write_0600(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| Error::bad(format!("keystore_dir: {error}")))?;
    }
    std::fs::write(path, bytes).map_err(|error| Error::bad(format!("keystore_write: {error}")))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::Permissions::from_mode(0o600);
        std::fs::set_permissions(path, mode)
            .map_err(|error| Error::bad(format!("keystore_chmod: {error}")))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests;
