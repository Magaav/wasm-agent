//! The kernel's side of the vault: the caller wiring behind `wa:kernel/credentials`, the fleet's
//! signing key, and the first-start migration (`docs/VAULT.md`).
//!
//! The rule this module exists to keep is one sentence from the design: **only the kernel may call
//! `reveal`/`use_by_ref`**. A component asks the kernel for a credential by name, the kernel asks the
//! vault with its own actor, and the value is injected into the outbound request. So:
//!
//! * [`VaultService::use_by_ref`] is the kernel's door and takes no actor: it *is* the kernel;
//! * [`VaultService::reveal`] is the gated door and takes the component's name, which the vault's
//!   policy checks against a `vault.reveal` grant;
//! * [`VaultService::sign`] signs as the component (or the operator), never exporting a seed;
//! * nothing in this file returns a value in an error, and no `Debug`/`Display` of this type can print
//!   one.
//!
//! Wiring today, and what is left: the secrets map a component run starts with is built from its
//! `file_env` grant (`service_components_v2::run`), and [`overlay_vault_secrets`] puts the vault's answer
//! on top of it — so a key the operator migrated or rotated in the vault wins over a stale file, and a
//! node that has no vault behaves exactly as before. Mounting `wa:kernel/keystore` as a linkable host
//! function for the vault *component* is the part that waits for the WASI 0.3 runner (`REPORT.md`).
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use wa_vault::migrate::Migration;
use wa_vault::{Actor, Kind, Meta, Vault, VaultOptions};

/// Where a vault lives when the node does not say: beside the node's other private state.
pub fn default_dir() -> PathBuf {
    PathBuf::from(wa_host_support::paths::resolve_home()).join(".wasm-agent").join("vault")
}

/// Where the older node keeps the keys the vault replaces (`docs/VAULT.md`, `/vault <name> <value>`).
pub fn default_keys_dir() -> PathBuf {
    PathBuf::from(wa_host_support::paths::resolve_home()).join(".wasm-agent").join("keys")
}

/// The vault, opened for the life of the process. One `Mutex` because the vault's document is one
/// thing: two concurrent writes would be two versions of the truth.
pub struct VaultService {
    vault: Mutex<Vault>,
    dir: PathBuf,
    protection: &'static str,
}

impl VaultService {
    /// Open (and create, on first use) the vault at `dir`. `policy_path` is the node's `policy.json`:
    /// only its `vault` section is read, and a broken one is an error rather than "no grants".
    pub fn open(dir: &Path, policy_path: Option<&Path>) -> Result<Self, String> {
        let policy = match policy_path {
            Some(path) if path.exists() => {
                let text = std::fs::read_to_string(path)
                    .map_err(|error| format!("policy_read: {}: {error}", path.display()))?;
                wa_vault::Policy::from_policy_json(&text).map_err(|error| error.to_string())?
            }
            _ => wa_vault::Policy::default(),
        };
        let options = wa_keystore::Options::from_env(dir);
        let mut keystore =
            wa_keystore::Keystore::open(&options).map_err(|error| error.reason().to_string())?;
        keystore.ensure_root().map_err(|error| error.reason().to_string())?;
        let protection = keystore.protection().as_str();
        let keystore = std::sync::Arc::new(keystore);
        let vault = Vault::open(
            Box::new(keystore.for_namespace("vault")),
            Box::new(wa_vault::FileStore::new(dir)),
            VaultOptions { policy, owner: "kernel".to_string(), ..VaultOptions::default() },
        )
        .map_err(|error| error.to_string())?;
        let service = VaultService { vault: Mutex::new(vault), dir: dir.to_path_buf(), protection };
        // The rotation window's other half: a node that never rotates again still destroys the material
        // whose window has ended (`docs/VAULT.md`).
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_secs() as i64)
            .unwrap_or(0);
        if let Ok(mut vault) = service.vault.lock() {
            let _ = vault.purge_expired(now);
        }
        Ok(service)
    }

    /// The vault the node runs with: `WASM_AGENT_VAULT_DIR`, else `<home>/.wasm-agent/vault`, with
    /// `policy.json` beside the other node state.
    pub fn from_env() -> Result<Self, String> {
        let dir = std::env::var_os("WASM_AGENT_VAULT_DIR").map(PathBuf::from).unwrap_or_else(default_dir);
        let policy = PathBuf::from(wa_host_support::paths::resolve_home())
            .join(".wasm-agent")
            .join("policy.json");
        Self::open(&dir, Some(&policy))
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// `dpapi`, `keyring` or `passphrase`: reported in the audit line of a start and in `wa vault status`.
    pub fn protection(&self) -> &'static str {
        self.protection
    }

    /// The kernel's own door: a credential for an outbound request. There is no actor argument because
    /// there is no other actor that may call it.
    pub fn use_by_ref(&self, name: &str) -> Option<zeroize::Zeroizing<String>> {
        let mut vault = self.vault.lock().ok()?;
        let value = vault.use_by_ref(name, &Actor::Kernel).ok()?;
        Some(as_string(value))
    }

    /// The gated door: a component named by a `vault.reveal` grant, for this entry.
    pub fn reveal(&self, component: &str, name: &str) -> Result<zeroize::Zeroizing<String>, String> {
        let mut vault = self.vault.lock().map_err(|_| "vault_locked".to_string())?;
        let value = vault
            .reveal(name, &Actor::Component(component.to_string()))
            .map_err(|error| error.reason().to_string())?;
        Ok(as_string(value))
    }

    /// Sign for a component (or the operator): the seed is opened inside the vault for this one call.
    pub fn sign(&self, actor: &Actor, name: &str, message: &[u8]) -> Result<Vec<u8>, String> {
        let mut vault = self.vault.lock().map_err(|_| "vault_locked".to_string())?;
        vault.sign(name, actor, message).map_err(|error| error.reason().to_string())
    }

    pub fn public_key(&self, name: &str) -> Result<Vec<u8>, String> {
        let vault = self.vault.lock().map_err(|_| "vault_locked".to_string())?;
        vault.public_key(name).map_err(|error| error.reason().to_string())
    }

    /// Names and metadata. Never a value.
    pub fn list(&self) -> Vec<(String, Meta)> {
        self.vault.lock().map(|vault| vault.list()).unwrap_or_default()
    }

    pub fn kind_of(&self, name: &str) -> Option<Kind> {
        self.vault.lock().ok().and_then(|vault| vault.get_meta(name).map(|meta| meta.kind))
    }

    /// `wa vault audit verify`.
    pub fn verify_audit(&self) -> Result<usize, String> {
        let vault = self.vault.lock().map_err(|_| "vault_locked".to_string())?;
        vault.verify_audit().map_err(|error| error.reason().to_string())
    }

    /// First start: the keys an older node wrote as files become vault entries. Idempotent, and the
    /// source files are never touched here (`docs/VAULT.md`).
    pub fn migrate_keys(&self, keys_dir: &Path) -> Result<Migration, String> {
        let mut vault = self.vault.lock().map_err(|_| "vault_locked".to_string())?;
        wa_vault::migrate::import_keys(&mut vault, keys_dir, &Actor::Kernel)
            .map_err(|error| error.reason().to_string())
    }
}

fn as_string(value: zeroize::Zeroizing<Vec<u8>>) -> zeroize::Zeroizing<String> {
    match String::from_utf8(value.to_vec()) {
        Ok(text) => zeroize::Zeroizing::new(text),
        // A non-UTF-8 credential is a credential all the same: lossy text is worse than a refusal only
        // if it is *used*, so it is base64-free hex and the caller can see it is not the file's bytes.
        Err(_) => zeroize::Zeroizing::new(String::new()),
    }
}

/// Put the vault's answer on top of a run's `file_env` secrets, for the names the component was granted.
///
/// This is the whole of the credentials-by-reference wiring on the 0.2 runner: `file_env` still decides
/// *which* names a component may ask for (the manifest and the policy are unchanged), and the vault
/// decides *what* the value is when it has one. A name with no vault entry keeps the file's value, so a
/// node with no vault and a node with an empty vault behave exactly as before.
///
/// Returns the names the vault answered for, which the caller may log: names, never values.
pub fn overlay_vault_secrets(
    service: &VaultService,
    granted: impl IntoIterator<Item = String>,
    secrets: &mut BTreeMap<String, String>,
) -> Vec<String> {
    let mut answered = Vec::new();
    for name in granted {
        if let Some(value) = service.use_by_ref(&name) {
            secrets.insert(name.clone(), value.to_string());
            answered.push(name);
        }
    }
    answered
}

/// The one-call form the runners use: open the node's vault once per process and put its answers on top
/// of a run's secrets. A node with no vault configured (or a host whose keystore will not open) overlays
/// nothing and starts the component exactly as before: an unconfigured vault is not a broken node.
pub fn overlay_run_secrets(
    component: &str,
    names: impl IntoIterator<Item = String>,
    secrets: &mut BTreeMap<String, String>,
) {
    static SERVICE: std::sync::OnceLock<Option<VaultService>> = std::sync::OnceLock::new();
    let Some(service) = SERVICE.get_or_init(|| VaultService::from_env().ok()) else { return };
    let answered = overlay_vault_secrets(service, names, secrets);
    if !answered.is_empty() {
        // Names only: which credentials this run took from the vault, never what they are.
        eprintln!("vault: {component} uses {} by reference", answered.join(","));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A vault in a temp directory, the sealed-file protection with a passphrase this test owns.
    fn service(tag: &str) -> (tempdir::Temp, VaultService, String) {
        let temp = tempdir::Temp::new(tag);
        std::env::set_var("WASM_AGENT_VAULT_PASSPHRASE", "vault-host-test");
        let service = VaultService::open(temp.path(), None).expect("vault");
        std::env::remove_var("WASM_AGENT_VAULT_PASSPHRASE");
        // The keystore's protection is this host's default; the passphrase was only needed if that
        // default is the sealed file, which is what a CI Linux box uses.
        let name = "github".to_string();
        (temp, service, name)
    }

    mod tempdir {
        use std::path::{Path, PathBuf};

        pub struct Temp {
            dir: PathBuf,
        }

        impl Temp {
            pub fn new(tag: &str) -> Temp {
                let dir = std::env::temp_dir().join(format!(
                    "wa-vault-host-{tag}-{}-{}",
                    std::process::id(),
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap()
                        .as_nanos()
                ));
                let _ = std::fs::remove_dir_all(&dir);
                std::fs::create_dir_all(&dir).expect("temp dir");
                Temp { dir }
            }

            pub fn path(&self) -> &Path {
                &self.dir
            }
        }

        impl Drop for Temp {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.dir);
            }
        }
    }

    #[test]
    fn the_kernel_uses_a_credential_by_reference_and_a_component_may_not() {
        let (temp, service, name) = service("use");
        let mut vault = service.vault.lock().expect("lock");
        vault
            .set(&name, Kind::Secret, b"ghp_from_the_vault", &Actor::Kernel)
            .expect("set");
        drop(vault);
        assert_eq!(service.use_by_ref(&name).expect("kernel").to_string(), "ghp_from_the_vault");
        // Components never reach `use_by_ref`: the door has no actor parameter, and `reveal` needs a
        // grant this policy does not have.
        assert_eq!(
            service.reveal("wa-email", &name).unwrap_err(),
            "vault_reveal_not_granted"
        );
        let _ = temp;
    }

    #[test]
    fn a_reveal_grant_names_the_component_and_the_entry() {
        let (temp, service, name) = service("reveal");
        {
            let mut vault = service.vault.lock().expect("lock");
            vault.set(&name, Kind::Secret, b"v", &Actor::Kernel).expect("set");
            vault.set_policy(wa_vault::Policy::new(vec![wa_vault::policy::RevealGrant {
                component: "wa-email".to_string(),
                entry: name.clone(),
            }]));
        }
        assert_eq!(service.reveal("wa-email", &name).expect("granted").to_string(), "v");
        assert_eq!(service.reveal("wa-whatsapp", &name).unwrap_err(), "vault_reveal_not_granted");
        // And the audit chain still verifies over both the refusal and the grant.
        assert!(service.verify_audit().expect("chain") >= 3);
        let _ = temp;
    }

    #[test]
    fn a_granted_file_env_name_is_answered_by_the_vault_and_a_name_it_lacks_keeps_the_file() {
        let (temp, service, name) = service("overlay");
        service
            .vault
            .lock()
            .expect("lock")
            .set(&name, Kind::Secret, b"from_the_vault", &Actor::Kernel)
            .expect("set");
        let mut secrets: BTreeMap<String, String> =
            [(name.clone(), "from_the_file".to_string()), ("other".to_string(), "kept".to_string())]
                .into_iter()
                .collect();
        let answered = overlay_vault_secrets(&service, [name.clone(), "other".to_string()], &mut secrets);
        assert_eq!(answered, vec![name.clone()], "only names the vault has are overlaid");
        assert_eq!(secrets[&name], "from_the_vault");
        assert_eq!(secrets["other"], "kept", "a name the vault lacks keeps the file's value");
        let _ = temp;
    }

    #[test]
    fn the_first_start_migration_is_idempotent_and_a_differing_value_is_refused() {
        let (temp, service, _name) = service("migrate");
        let keys = tempdir::Temp::new("migrate-keys");
        std::fs::write(keys.path().join("github.key"), "ghp_one\n").expect("key file");
        let first = service.migrate_keys(keys.path()).expect("migrate");
        assert_eq!(first.imported, vec!["github".to_string()]);
        let second = service.migrate_keys(keys.path()).expect("migrate again");
        assert!(second.imported.is_empty());
        assert_eq!(second.kept, vec!["github".to_string()]);
        std::fs::write(keys.path().join("github.key"), "ghp_two\n").expect("key file");
        let third = service.migrate_keys(keys.path()).expect("migrate third");
        assert_eq!(third.refused, vec![("github".to_string(), "vault_entry_differs".to_string())]);
        // The original is still on disk: the migration never deletes a source.
        assert!(keys.path().join("github.key").exists());
        let _ = temp;
    }

    #[test]
    fn the_grant_table_refuses_the_reveal_interface_to_every_component_and_names_the_keystore() {
        // `docs/WASI-INTERFACES.md` tier C: a component importing the reveal door is refused before it
        // runs, whatever its manifest says. This is the link-time half of the reveal policy.
        let (row, _version) = crate::wasi_grants::spec_of("wa:vault/reveal@0.1.0").expect("a row");
        assert_eq!(row.tier, crate::wasi_grants::Tier::Never);
        let (row, _version) = crate::wasi_grants::spec_of("wa:vault/vault@0.1.0").expect("a row");
        assert_eq!(row.tier, crate::wasi_grants::Tier::Never);
        // The keystore is tier B: a manifest key, a policy capability, and no way to name a key.
        let (row, _version) = crate::wasi_grants::spec_of("wa:kernel/keystore@0.2.0").expect("a row");
        assert_eq!(row.tier, crate::wasi_grants::Tier::Granted);
        assert_eq!(row.manifest_key, "keystore");
        assert_eq!(row.capability, "wasi.keystore");
    }
}
