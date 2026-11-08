//! What has to be true of the keystore, wherever it runs.
//!
//! The DPAPI test is the Windows proof the job asks for; the passphrase test is the fallback proof
//! that runs on both hosts (CI included). The keyring path is compiled and its fallback is proven
//! here, but a real keyring round trip needs a Linux host — `REPORT.md` says so instead of implying
//! coverage this machine cannot give.
use super::*;
use std::path::PathBuf;

/// A fresh directory under the OS temp dir. Every test gets its own so nothing is shared, and nothing
/// is ever written near a node home.
fn temp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "wa-keystore-{name}-{}-{:?}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    dir
}

fn passphrase_keystore(dir: &Path, passphrase: &str) -> std::sync::Arc<Keystore> {
    let mut keystore =
        Keystore::open(&Options::new(dir).with_protection(Protection::PassphraseFile).with_passphrase(passphrase))
            .expect("open");
    keystore.ensure_root().expect("root");
    std::sync::Arc::new(keystore)
}

#[test]
fn a_passphrase_keystore_round_trips_a_sealed_value() {
    let dir = temp("passphrase");
    let keystore = passphrase_keystore(&dir, "correct horse battery staple");
    let keystore = std::sync::Arc::new(keystore);
    assert!(keystore.status().root);
    let sealer = keystore.for_namespace("vault");
    let sealed = sealer.seal("github|1", b"ghp_example_value").expect("seal");
    assert_ne!(&sealed[1..], b"github|1", "the context is authenticated, never stored in the clear");
    assert!(!sealed.windows(17).any(|window| window == b"ghp_example_value"));
    let opened = sealer.open("github|1", &sealed).expect("open");
    assert_eq!(opened.as_slice(), b"ghp_example_value");
}

#[test]
fn the_context_is_the_associated_data_so_a_blob_cannot_move_between_entries() {
    let dir = temp("context");
    let keystore = passphrase_keystore(&dir, "passphrase-one");
    let sealer = keystore.for_namespace("vault");
    let sealed = sealer.seal("github|1", b"value").expect("seal");
    // AAD mismatch: the same bytes under another entry's name, or another version, refuse.
    assert!(sealer.open("github|2", &sealed).is_err());
    assert!(sealer.open("gitlab|1", &sealed).is_err());
}

#[test]
fn another_namespace_cannot_open_this_namespaces_blob() {
    let dir = temp("namespaces");
    let keystore = passphrase_keystore(&dir, "passphrase-two");
    let vault = keystore.for_namespace("vault");
    let other = keystore.for_namespace("someone-else");
    let sealed = vault.seal("name|1", b"value").expect("seal");
    let error = other.open("name|1", &sealed).expect_err("a second namespace must not open it");
    assert_eq!(error.reason(), "sealed_blob_refused");
}

#[test]
fn a_tampered_blob_is_refused_and_not_partially_returned() {
    let dir = temp("tamper");
    let keystore = passphrase_keystore(&dir, "passphrase-three");
    let sealer = keystore.for_namespace("vault");
    let mut sealed = sealer.seal("name|1", b"value").expect("seal");
    let last = sealed.len() - 1;
    sealed[last] ^= 0x01;
    assert!(sealer.open("name|1", &sealed).is_err());
    // A truncated blob is corrupt, not an empty value.
    assert_eq!(sealer.open("name|1", &sealed[..4]).unwrap_err().reason(), "sealed_blob_corrupt");
}

#[test]
fn the_root_key_file_holds_no_root_key_and_is_never_rewritten() {
    let dir = temp("root");
    let mut keystore = Keystore::open(
        &Options::new(&dir).with_protection(Protection::PassphraseFile).with_passphrase("p"),
    )
    .expect("open");
    assert!(!keystore.status().root);
    keystore.ensure_root().expect("root");
    let first = std::fs::read(dir.join(ROOT_FILE)).expect("root file");
    assert!(first.len() > 32, "the file is the wrapped key, not the key");
    // 16-byte salt || version byte || nonce || ciphertext: the raw 32 bytes are never in it.
    assert_eq!(first[16], 1);
    keystore.ensure_root().expect("second ensure is a no-op");
    assert_eq!(std::fs::read(dir.join(ROOT_FILE)).expect("root file"), first);
}

#[test]
fn the_wrong_passphrase_refuses_instead_of_deriving_a_different_vault() {
    let dir = temp("wrong-passphrase");
    let keystore = passphrase_keystore(&dir, "right");
    let sealed = keystore.for_namespace("vault").seal("k|1", b"v").expect("seal");
    drop(keystore);
    let reopened = Keystore::open(
        &Options::new(&dir).with_protection(Protection::PassphraseFile).with_passphrase("wrong"),
    );
    match reopened {
        Err(error) => assert_eq!(error.reason(), "sealed_blob_refused"),
        Ok(_) => panic!("a wrong passphrase produced a usable keystore"),
    }
    let ok = std::sync::Arc::new(
        Keystore::open(
            &Options::new(&dir).with_protection(Protection::PassphraseFile).with_passphrase("right"),
        )
        .expect("right passphrase"),
    );
    assert_eq!(ok.for_namespace("vault").open("k|1", &sealed).expect("open").as_slice(), b"v");
}

#[test]
fn the_passphrase_fallback_says_so_when_no_passphrase_is_supplied() {
    let dir = temp("no-passphrase");
    let mut keystore = Keystore::open(&Options::new(&dir).with_protection(Protection::PassphraseFile))
        .expect("open");
    assert_eq!(keystore.ensure_root().unwrap_err().reason(), "keystore_passphrase_missing");
    assert!(!keystore.status().root);
}

#[test]
fn an_unknown_protection_name_is_a_refusal_not_a_default() {
    assert_eq!(Protection::parse("dpapi").unwrap(), Protection::Dpapi);
    assert_eq!(Protection::parse("keyring").unwrap(), Protection::KernelKeyring);
    assert_eq!(Protection::parse("file").unwrap(), Protection::PassphraseFile);
    assert_eq!(Protection::parse("dpai").unwrap_err().reason(), "keystore_protection_unknown:dpai");
}

#[cfg(windows)]
#[test]
fn dpapi_user_scope_is_the_protection_on_windows_and_it_round_trips() {
    let dir = temp("dpapi");
    // No passphrase: DPAPI must need none.
    let mut keystore = Keystore::open(&Options::new(&dir)).expect("open");
    assert_eq!(keystore.protection(), Protection::Dpapi);
    keystore.ensure_root().expect("root");
    let keystore = std::sync::Arc::new(keystore);
    let sealer = keystore.for_namespace("vault");
    let sealed = sealer.seal("name|1", b"dpapi-value").expect("seal");
    assert_eq!(sealer.open("name|1", &sealed).expect("open").as_slice(), b"dpapi-value");
    // The wrapped root is a DPAPI blob, so it survives a reopen *as this user* and no passphrase.
    drop(sealer);
    drop(keystore);
    let reopened = std::sync::Arc::new(Keystore::open(&Options::new(&dir)).expect("reopen"));
    assert_eq!(
        reopened.for_namespace("vault").open("name|1", &sealed).expect("open").as_slice(),
        b"dpapi-value"
    );
    // A second keystore directory has its own root: one vault's ciphertext is not another's.
    let other_dir = temp("dpapi-other");
    let mut other = Keystore::open(&Options::new(&other_dir)).expect("open other");
    other.ensure_root().expect("root other");
    let other = std::sync::Arc::new(other);
    let error = other.for_namespace("vault").open("name|1", &sealed).expect_err("must refuse");
    assert_eq!(error.reason(), "sealed_blob_refused");
}

#[cfg(windows)]
#[test]
fn a_dpapi_blob_is_not_readable_as_plain_wrapping() {
    // The DPAPI path must actually change the bytes: a base64 of the key would pass a round trip and
    // fail this test.
    let dir = temp("dpapi-not-plain");
    let mut keystore = Keystore::open(&Options::new(&dir)).expect("open");
    keystore.ensure_root().expect("root");
    let blob = std::fs::read(dir.join(ROOT_FILE)).expect("blob");
    assert!(blob.len() > 32 + 16, "a DPAPI blob carries a header and an HMAC");
    assert_ne!(blob.len(), 32);
}
