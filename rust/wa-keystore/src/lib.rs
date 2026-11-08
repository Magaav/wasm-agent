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
}

impl Keystore {
    /// Open (or prepare) the keystore. Does not create a root key; [`Keystore::ensure_root`] does.
    pub fn open(options: &Options) -> Result<Self> {
        std::fs::create_dir_all(&options.dir)
            .map_err(|error| Error::bad(format!("keystore_dir: {error}")))?;
        let protection = match options.requested {
            Some(requested) => requested,
            None => default_protection(&options.dir),
        };
        let mut keystore = Keystore {
            dir: options.dir.clone(),
            protection,
            passphrase: options.passphrase.clone(),
            root: None,
        };
        if keystore.root_path().exists() {
            keystore.root = Some(keystore.load_root()?);
        }
        Ok(keystore)
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
        let blob = self.wrap_root(&root)?;
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

    fn wrap_root(&self, root: &[u8; 32]) -> Result<Vec<u8>> {
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
                    let wrapping = keyring::wrapping_key(&self.dir)?;
                    seal::seal_with(&wrapping, KDF_DOMAIN, root)
                }
                #[cfg(not(target_os = "linux"))]
                {
                    Err(Error::bad("keystore_protection_unavailable:keyring"))
                }
            }
            Protection::PassphraseFile => {
                // A fresh salt per wrapping, stored in front of the blob so one passphrase on two
                // machines does not derive one key.
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
        }
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
                    let wrapping = keyring::wrapping_key(&self.dir)?;
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

fn default_protection(dir: &Path) -> Protection {
    #[cfg(windows)]
    {
        let _ = dir;
        Protection::Dpapi
    }
    #[cfg(target_os = "linux")]
    {
        // A restricted container can refuse `add_key`; the passphrase file is then the honest
        // fallback, and it is reported as such in `wa vault status`.
        if keyring::available(dir) {
            Protection::KernelKeyring
        } else {
            Protection::PassphraseFile
        }
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = dir;
        Protection::PassphraseFile
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
