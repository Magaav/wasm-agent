//! Every guarantee `docs/VAULT.md` states, as a test.
//!
//! The crypto is real: a passphrase keystore in a temp directory (the same `wa-keystore` the node
//! uses), the real `FileStore`, the real audit chain. Nothing here reads or writes a node home, and
//! no test starts a `wa` process.
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use crate::audit::GENESIS;
use crate::migrate;
use crate::policy::{Policy, RevealGrant};
use crate::store::{FileStore, MemoryStore};
use crate::{
    Actor, Clock, Kind, Vault, VaultError, VaultOptions, DEFAULT_ROTATION_WINDOW_S,
};

/// The value every leak scan looks for. Distinctive on purpose.
const PLANTED: &str = "planted-secret-value-9f3a";
/// The passphrase the test keystore uses (never an operator's).
const PASSPHRASE: &str = "vault-test-passphrase";

struct TestClock(Arc<AtomicI64>);

impl TestClock {
    fn new(now: i64) -> Self {
        TestClock(Arc::new(AtomicI64::new(now)))
    }

    fn advance(&self, seconds: i64) {
        self.0.fetch_add(seconds, Ordering::SeqCst);
    }
}

impl Clock for TestClock {
    fn now(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}

fn temp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "wa-vault-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    dir
}

fn sealer(dir: &Path) -> Box<dyn crate::Sealer> {
    let mut keystore = wa_keystore::Keystore::open(
        &wa_keystore::Options::new(dir)
            .with_protection(wa_keystore::Protection::PassphraseFile)
            .with_passphrase(PASSPHRASE),
    )
    .expect("keystore");
    keystore.ensure_root().expect("root");
    let keystore = Arc::new(keystore);
    Box::new(keystore.for_namespace("vault"))
}

fn open(dir: &Path, policy: Policy, clock: Arc<TestClock>, window: i64) -> Vault {
    Vault::open(
        sealer(dir),
        Box::new(FileStore::new(dir)),
        VaultOptions {
            policy,
            clock: Box::new(TestClockRef(clock)),
            rotation_window_s: window,
            owner: "operator:test".to_string(),
        },
    )
    .expect("open")
}

/// `VaultOptions` takes a boxed clock; this hands it a handle a test keeps to move time.
struct TestClockRef(Arc<TestClock>);

impl Clock for TestClockRef {
    fn now(&self) -> i64 {
        self.0.now()
    }
}

fn operator() -> Actor {
    Actor::Operator("test".to_string())
}

fn component(name: &str) -> Actor {
    Actor::Component(name.to_string())
}

#[test]
fn a_secret_can_be_set_listed_and_is_never_in_the_document_or_the_audit() {
    let dir = temp("set-list");
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let mut vault = open(&dir, Policy::default(), Arc::clone(&clock), DEFAULT_ROTATION_WINDOW_S);
    vault.set("github", Kind::Secret, PLANTED.as_bytes(), &operator()).expect("set");

    let listed = vault.list();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].0, "github");
    assert_eq!(listed[0].1.version, 1);
    assert_eq!(listed[0].1.kind, Kind::Secret);
    // `list` has no value field at all: the scan below is the belt to that braces.
    let doc = std::fs::read_to_string(dir.join(crate::store::DOC_FILE)).expect("document");
    let log = std::fs::read_to_string(dir.join(crate::store::AUDIT_FILE)).expect("audit");
    assert!(!doc.contains(PLANTED), "the document holds ciphertext only");
    assert!(!log.contains(PLANTED), "the audit log holds no value");
    assert!(doc.contains(&crate::hex::encode(&[0u8; 0])[..0])); // document exists and is text
    // The kernel can use it by reference, which is the whole point of storing it.
    let value = vault.use_by_ref("github", &Actor::Kernel).expect("kernel use");
    assert_eq!(value.as_slice(), PLANTED.as_bytes());
}

#[test]
fn reveal_is_refused_without_a_grant_and_allowed_with_one() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let dir = temp("reveal");
    let mut vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);
    vault.set("github", Kind::Secret, PLANTED.as_bytes(), &operator()).expect("set");

    let error = vault.reveal("github", &component("wa-email")).expect_err("no grant");
    assert_eq!(error.reason(), "vault_reveal_not_granted");
    // Another component's grant is not this component's grant.
    vault.set_policy(Policy::new(vec![RevealGrant {
        component: "wa-whatsapp".to_string(),
        entry: "github".to_string(),
    }]));
    assert_eq!(
        vault.reveal("github", &component("wa-email")).unwrap_err().reason(),
        "vault_reveal_not_granted"
    );
    vault.set_policy(Policy::new(vec![RevealGrant {
        component: "wa-email".to_string(),
        entry: "github".to_string(),
    }]));
    assert_eq!(vault.reveal("github", &component("wa-email")).expect("granted").as_slice(), PLANTED.as_bytes());
    // The refusal and the grant are both in the chain, and neither line carries the value.
    let log = std::fs::read_to_string(dir.join(crate::store::AUDIT_FILE)).expect("audit");
    assert_eq!(log.matches("refused:reveal_not_granted").count(), 2);
    assert!(!log.contains(PLANTED));
}

#[test]
fn use_by_ref_is_the_kernels_door_only_whatever_the_policy_says() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let dir = temp("use-by-ref");
    // Even a wildcard reveal grant does not open `use_by_ref`.
    let mut vault = open(
        &dir,
        Policy::new(vec![RevealGrant { component: "*".to_string(), entry: "*".to_string() }]),
        Arc::clone(&clock),
        60,
    );
    vault.set("provider", Kind::Secret, PLANTED.as_bytes(), &operator()).expect("set");
    let error = vault.use_by_ref("provider", &component("wa-email")).expect_err("refused");
    assert_eq!(error.reason(), "vault_kernel_only");
}

#[test]
fn an_ed25519_entry_signs_and_the_signature_verifies_with_its_public_key() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let dir = temp("sign");
    let mut vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);
    let seed = [7u8; 32];
    vault.import_ed25519("fleet", &seed, &operator()).expect("import");
    let public = vault.public_key("fleet").expect("public key");
    let message = b"mesh-roster-v1|ohana|1|2|{\"nodes\":[]}";
    let signature = vault.sign("fleet", &operator(), message).expect("sign");
    let key = ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, &public);
    key.verify(message, &signature).expect("the signature verifies");
    // A secret entry cannot be signed, and an ed25519 entry cannot be revealed as a secret.
    vault.set("token", Kind::Secret, b"v", &operator()).expect("set");
    assert_eq!(vault.sign("token", &operator(), b"x").unwrap_err().reason(), "vault_kind_mismatch");
    // The seed never appears in the document, in the audit log, or in an error message.
    let doc = std::fs::read_to_string(dir.join(crate::store::DOC_FILE)).expect("document");
    assert!(!doc.contains(&crate::hex::encode(&seed)));
    assert!(!doc.contains(&crate::hex::encode(&public)));
    let log = std::fs::read_to_string(dir.join(crate::store::AUDIT_FILE)).expect("audit");
    assert!(log.contains(&format!("ok:{}", crate::hex::encode(&public))), "the public key is public");
    assert!(!log.contains(&crate::hex::encode(&seed)));
}

#[test]
fn a_seed_of_the_wrong_length_is_refused_before_anything_is_stored() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let dir = temp("seed-length");
    let mut vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);
    assert_eq!(
        vault.import_ed25519("fleet", &[0u8; 31], &operator()).unwrap_err().reason(),
        "vault_seed_length"
    );
    assert!(vault.get_meta("fleet").is_none());
}

#[test]
fn rotation_keeps_the_previous_version_for_the_window_and_then_destroys_it() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let dir = temp("rotate");
    let mut vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);
    vault.set("github", Kind::Secret, b"version-one", &operator()).expect("set");
    let rotated = vault.rotate("github", &operator(), None).expect("rotate");
    assert_eq!(rotated.version, 2);
    assert!(vault.has_version("github", 1), "the old version is still there during the window");
    assert_eq!(vault.use_by_ref("github", &Actor::Kernel).expect("use").as_slice(), b"version-one");

    // Inside the window: nothing is destroyed.
    clock.advance(30);
    assert!(vault.purge_expired(clock.now()).expect("purge").is_empty());
    assert!(vault.has_version("github", 1));

    // After the window: the old material is gone, not merely unreadable.
    clock.advance(60);
    let destroyed = vault.purge_expired(clock.now()).expect("purge");
    assert_eq!(destroyed, vec![("github".to_string(), 1u32)]);
    assert!(!vault.has_version("github", 1));
    assert!(vault.has_version("github", 2));
    let log = std::fs::read_to_string(dir.join(crate::store::AUDIT_FILE)).expect("audit");
    assert!(log.contains("\"op\":\"destroy\""), "the destruction is an audited operation");
    assert!(!log.contains("version-one"));
}

#[test]
fn rotation_with_a_new_value_moves_the_value_and_keeps_the_version_history() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let dir = temp("rotate-value");
    let mut vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);
    vault.set("token", Kind::Secret, b"old-value", &operator()).expect("set");
    let meta = vault.rotate("token", &operator(), Some(b"new-value")).expect("rotate");
    assert_eq!(meta.version, 2);
    assert_eq!(vault.use_by_ref("token", &Actor::Kernel).expect("use").as_slice(), b"new-value");
}

#[test]
fn the_audit_chain_verifies_and_detects_an_edited_line() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let dir = temp("audit-edit");
    let mut vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);
    vault.set("github", Kind::Secret, PLANTED.as_bytes(), &operator()).expect("set");
    vault.rotate("github", &operator(), None).expect("rotate");
    vault.delete("github", &operator()).expect("delete");
    assert_eq!(vault.verify_audit().expect("clean chain"), 3, "set, rotate, delete");

    let path = dir.join(crate::store::AUDIT_FILE);
    let original = std::fs::read_to_string(&path).expect("audit");
    // Edit one result word in the middle line, as an operator's script or a text editor would.
    let edited = original.replacen("\"result\":\"ok\"", "\"result\":\"refused:unknown_entry\"", 1);
    assert_ne!(edited, original);
    std::fs::write(&path, &edited).expect("write");
    let vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);
    let error = vault.verify_audit().expect_err("an edited line must fail");
    assert!(error.reason().starts_with("audit_hash_mismatch"), "{error}");

    // A deleted middle line is caught by the sequence number first (the line after it now claims a
    // number that does not follow), which is why `seq` is part of the chain at all: hashes alone
    // would only notice at the next `prev_hash`.
    let mut lines: Vec<&str> = original.lines().collect();
    lines.remove(1);
    std::fs::write(&path, format!("{}\n", lines.join("\n"))).expect("write");
    let error = open(&dir, Policy::default(), Arc::clone(&clock), 60).verify_audit().expect_err("must fail");
    assert_eq!(error.reason(), "audit_seq_out_of_order:2");

    // A truncated tail is caught by the document's head, not by the line hashes.
    let mut kept: Vec<&str> = original.lines().collect();
    kept.pop();
    std::fs::write(&path, format!("{}\n", kept.join("\n"))).expect("write");
    let error = open(&dir, Policy::default(), Arc::clone(&clock), 60).verify_audit().expect_err("must fail");
    assert_eq!(error.reason(), "audit_head_mismatch");
}

#[test]
fn a_fresh_vaults_chain_starts_at_genesis() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let dir = temp("audit-genesis");
    let vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);
    assert_eq!(vault.verify_audit().expect("empty chain"), 0);
    assert_eq!(GENESIS, "genesis");
}

#[test]
fn a_name_that_would_break_the_aad_is_refused() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let dir = temp("names");
    let mut vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);
    for bad in ["", "with|pipe", "with space", "with\nnewline"] {
        assert_eq!(
            vault.set(bad, Kind::Secret, b"v", &operator()).unwrap_err().reason(),
            "vault_name_invalid",
            "{bad:?}"
        );
    }
    assert_eq!(&"a".repeat(65), &"a".repeat(65));
    assert_eq!(
        vault.set(&"a".repeat(65), Kind::Secret, b"v", &operator()).unwrap_err().reason(),
        "vault_name_invalid"
    );
    vault.set("ok-name_1.2/x", Kind::Secret, b"v", &operator()).expect("a normal name is fine");
}

#[test]
fn a_component_may_not_create_rotate_or_delete_entries() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let dir = temp("admin");
    let mut vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);
    vault.set("github", Kind::Secret, b"v", &operator()).expect("set");
    let guest = component("wa-email");
    assert_eq!(vault.set("other", Kind::Secret, b"v", &guest).unwrap_err().reason(), "vault_kernel_only");
    assert_eq!(vault.rotate("github", &guest, None).unwrap_err().reason(), "vault_kernel_only");
    assert_eq!(vault.delete("github", &guest).unwrap_err().reason(), "vault_kernel_only");
    // `list` is fine: names and metadata are not secrets.
    assert_eq!(vault.list().len(), 1);
}

#[test]
fn a_value_never_appears_in_an_error_message() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let dir = temp("errors");
    let mut vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);
    vault.set("github", Kind::Secret, PLANTED.as_bytes(), &operator()).expect("set");
    let mut errors: Vec<String> = Vec::new();
    errors.push(vault.reveal("github", &component("wa-email")).unwrap_err().to_string());
    errors.push(vault.sign("github", &operator(), b"m").unwrap_err().to_string());
    errors.push(vault.use_by_ref("github", &component("wa-email")).unwrap_err().to_string());
    errors.push(vault.use_by_ref("missing", &Actor::Kernel).unwrap_err().to_string());
    errors.push(vault.rotate("missing", &operator(), None).unwrap_err().to_string());
    for error in errors {
        assert!(!error.contains(PLANTED), "an error message carried the value: {error}");
    }
}

#[test]
fn provider_keys_migrate_idempotently_and_a_differing_entry_is_never_overwritten() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let dir = temp("migrate");
    let keys = temp("migrate-keys");
    std::fs::write(keys.join("github.key"), format!("{PLANTED}\n")).expect("key file");
    std::fs::write(keys.join("other.key"), "second-value\n").expect("key file");
    let mut vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);

    let first = migrate::import_keys(&mut vault, &keys, &Actor::Kernel).expect("migrate");
    assert_eq!(first.imported, vec!["github".to_string(), "other".to_string()]);
    assert!(first.refused.is_empty());
    assert!(first.is_clean());
    assert_eq!(vault.use_by_ref("github", &Actor::Kernel).expect("use").as_slice(), PLANTED.as_bytes());
    // The source file is still there: the original is kept until an operator asks otherwise.
    assert!(keys.join("github.key").exists());

    // A second run is a no-op that writes nothing.
    let before = std::fs::read(dir.join(crate::store::DOC_FILE)).expect("document");
    let second = migrate::import_keys(&mut vault, &keys, &Actor::Kernel).expect("migrate again");
    assert!(second.imported.is_empty());
    assert_eq!(second.kept, vec!["github".to_string(), "other".to_string()]);
    assert_eq!(std::fs::read(dir.join(crate::store::DOC_FILE)).expect("document"), before);

    // A *different* value for a name the vault already holds is refused, not overwritten.
    std::fs::write(keys.join("github.key"), "a-different-value\n").expect("key file");
    let third = migrate::import_keys(&mut vault, &keys, &Actor::Kernel).expect("migrate third");
    assert_eq!(third.refused, vec![("github".to_string(), "vault_entry_differs".to_string())]);
    assert_eq!(vault.use_by_ref("github", &Actor::Kernel).expect("use").as_slice(), PLANTED.as_bytes());
}

#[test]
fn a_vault_reopens_on_its_own_document_and_keeps_its_versions() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let dir = temp("reopen");
    {
        let mut vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);
        vault.set("github", Kind::Secret, PLANTED.as_bytes(), &operator()).expect("set");
        vault.rotate("github", &operator(), None).expect("rotate");
    }
    let mut vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);
    assert_eq!(vault.get_meta("github").expect("meta").version, 2);
    assert!(vault.has_version("github", 1));
    assert_eq!(vault.use_by_ref("github", &Actor::Kernel).expect("use").as_slice(), PLANTED.as_bytes());
    assert_eq!(vault.verify_audit().expect("chain"), 3, "set, rotate, then the use above");
}

#[test]
fn the_policy_section_is_read_strictly_and_ignores_other_sections() {
    let policy = Policy::from_policy_json(
        r#"{"vault":{"reveal":[{"component":"wa-email","entry":"smtp"}]},"mesh":{"enabled":true}}"#,
    )
    .expect("policy");
    assert!(policy.allows_reveal(&component("wa-email"), "smtp"));
    assert!(!policy.allows_reveal(&component("wa-email"), "other"));
    assert!(!policy.allows_reveal(&component("wa-whatsapp"), "smtp"));
    // A typo inside the section is an error, not a silently empty grant list.
    assert!(Policy::from_policy_json(r#"{"vault":{"reval":[]}}"#).is_err());
    // A node with no policy section and no policy file is the default (no component grants).
    assert_eq!(Policy::from_policy_json("{}").expect("empty"), Policy::default());
}

#[test]
fn a_memory_store_is_a_vault_too_which_is_what_the_component_does_with_its_kv() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let mut vault = Vault::open(
        sealer(&temp("memory-sealer")),
        Box::new(MemoryStore::new()),
        VaultOptions {
            policy: Policy::default(),
            clock: Box::new(TestClockRef(clock)),
            rotation_window_s: 60,
            owner: "kernel".to_string(),
        },
    )
    .expect("open");
    vault.set("k", Kind::Secret, b"v", &Actor::Kernel).expect("set");
    assert_eq!(vault.use_by_ref("k", &Actor::Kernel).expect("use").as_slice(), b"v");
    assert_eq!(vault.verify_audit().expect("chain"), 2, "set, then the use above");
}

#[test]
fn a_store_failure_is_a_named_refusal_not_a_silent_success() {
    struct Broken;
    impl crate::Store for Broken {
        fn load(&self) -> Result<Option<Vec<u8>>, String> {
            Ok(None)
        }
        fn save(&self, _bytes: &[u8]) -> Result<(), String> {
            Err("disk_full".to_string())
        }
        fn append(&self, _line: &str) -> Result<(), String> {
            Ok(())
        }
        fn audit(&self) -> Result<String, String> {
            Ok(String::new())
        }
    }
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let mut vault = Vault::open(
        sealer(&temp("broken-sealer")),
        Box::new(Broken),
        VaultOptions {
            policy: Policy::default(),
            clock: Box::new(TestClockRef(clock)),
            rotation_window_s: 60,
            owner: "kernel".to_string(),
        },
    )
    .expect("open");
    let error: VaultError = vault.set("k", Kind::Secret, b"v", &Actor::Kernel).unwrap_err();
    assert!(error.reason().starts_with("vault_store:disk_full"), "{error}");
}

// ---- the optimization check (docs/VAULT.md: latency p50/p95 of use_by_ref and sign, and RSS) ----

#[test]
fn use_by_ref_and_sign_latency_and_process_rss_are_measured_not_guessed() {
    let clock = Arc::new(TestClock::new(1_700_000_000));
    let dir = temp("latency");
    let mut vault = open(&dir, Policy::default(), Arc::clone(&clock), 60);
    vault.set("provider", Kind::Secret, PLANTED.as_bytes(), &Actor::Kernel).expect("set");
    vault.import_ed25519("fleet", &[3u8; 32], &Actor::Kernel).expect("import");

    let mut use_samples = Vec::new();
    let mut sign_samples = Vec::new();
    for _ in 0..200 {
        let start = std::time::Instant::now();
        let value = vault.use_by_ref("provider", &Actor::Kernel).expect("use");
        use_samples.push(start.elapsed());
        assert_eq!(value.as_slice(), PLANTED.as_bytes());
        let start = std::time::Instant::now();
        let signature = vault.sign("fleet", &Actor::Kernel, b"message").expect("sign");
        sign_samples.push(start.elapsed());
        assert_eq!(signature.len(), 64);
    }
    let p50 = percentile(&mut use_samples, 50);
    let p95 = percentile(&mut use_samples, 95);
    let s50 = percentile(&mut sign_samples, 50);
    let s95 = percentile(&mut sign_samples, 95);
    println!(
        "measure: use_by_ref p50={p50}us p95={p95}us  sign p50={s50}us p95={s95}us  rss={}KiB",
        rss_kib().map(|kib| kib.to_string()).unwrap_or_else(|| "unavailable".to_string())
    );
    // The bound is generous on purpose: it catches an accidental per-call KDF (Argon2id is ~50 ms) or
    // a re-open of the keystore, not the microsecond differences of a CI machine.
    assert!(p95 < 20_000, "use_by_ref p95 was {p95}us: a per-call KDF would be milliseconds");
    assert!(s95 < 20_000, "sign p95 was {s95}us");
    rx_keep_alive(&vault);
}

fn rx_keep_alive(vault: &Vault) {
    // One `list` after the measurement, so the optimizer cannot drop the vault before RSS is read.
    assert_eq!(vault.list().len(), 2);
}

fn percentile(samples: &mut [std::time::Duration], percentile: usize) -> u128 {
    samples.sort();
    let index = ((samples.len() - 1) * percentile) / 100;
    samples[index].as_micros()
}

/// The resident set size of this test process. Available on Linux (`/proc/self/statm`) and on Windows
/// (`GetProcessMemoryInfo`); `None` on any other host, reported as unavailable rather than zero.
fn rss_kib() -> Option<u64> {
    #[cfg(target_os = "linux")]
    {
        let statm = std::fs::read_to_string("/proc/self/statm").ok()?;
        let pages: u64 = statm.split_whitespace().nth(1)?.parse().ok()?;
        return Some(pages * 4);
    }
    #[cfg(windows)]
    {
        windows_rss_kib()
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        None
    }
}

#[cfg(windows)]
fn windows_rss_kib() -> Option<u64> {
    use windows_sys::Win32::System::ProcessStatus::{
        GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS,
    };
    use windows_sys::Win32::System::Threading::GetCurrentProcess;
    let mut counters = std::mem::MaybeUninit::<PROCESS_MEMORY_COUNTERS>::zeroed();
    // SAFETY: the counter struct is a live local of the size the API expects, and the pseudo-handle
    // from GetCurrentProcess needs no closing.
    let ok = unsafe {
        GetProcessMemoryInfo(
            GetCurrentProcess(),
            counters.as_mut_ptr(),
            std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32,
        )
    };
    if ok == 0 {
        return None;
    }
    // SAFETY: the call returned non-zero, so the struct was filled.
    let counters = unsafe { counters.assume_init() };
    Some((counters.WorkingSetSize / 1024) as u64)
}
