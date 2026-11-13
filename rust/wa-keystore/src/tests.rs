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

// ---- the two failures measured inside the fast path on wa-desktop (13/11) ---------------------------
//
// 1. `sealed_blob_version_unknown` on an intact file. The wrapped root's shape depends on which
//    protection wrote it (73 bytes under the keyring, 89 with the passphrase file's salt), the
//    protection was chosen per process from a mutable machine resource, and nothing recorded the choice
//    — so a keyring-wrapped file read on the passphrase path had its version byte taken from the
//    keyring blob's nonce.
// 2. `keystore_keyring_unavailable` on a machine whose uid had spent its 200-key quota, because the
//    availability probe invalidated (never released) one entry per `wa vault` command.

/// A wrapped-root file says which protection wrote it, and the two shapes are exact.
#[cfg(not(windows))]
#[test]
fn the_root_file_shape_says_which_protection_wrote_it() {
    let dir = temp("shape");
    let keystore = passphrase_keystore(&dir, "p");
    drop(keystore);
    let file = std::fs::read(dir.join(ROOT_FILE)).expect("root file");
    assert_eq!(file.len(), PASSPHRASE_ROOT_LEN);
    assert_eq!(Protection::from_root_file(&file), Some(Protection::PassphraseFile));

    // The keyring shape is the sealed blob on its own: 32-byte root in, `version || nonce || ct+tag` out.
    let keyring_blob =
        seal::seal_with(&[7u8; 32], KDF_DOMAIN, &[9u8; 32]).expect("seal a root as the keyring does");
    assert_eq!(keyring_blob.len(), SEALED_ROOT_LEN);
    assert_eq!(Protection::from_root_file(&keyring_blob), Some(Protection::KernelKeyring));

    // Anything else is not a wrapped root, and is refused by name rather than guessed at.
    assert_eq!(Protection::from_root_file(&[1u8; 10]), None);
    assert_eq!(Protection::from_root_file(&[]), None);
}

/// The reported failure, at the level it happened: a vault written with the passphrase file is read with
/// the passphrase file — even on a host whose keyring would otherwise be preferred, which is exactly the
/// case that answered `sealed_blob_version_unknown` for a file nobody had touched.
#[test]
fn a_passphrase_root_file_is_read_with_the_passphrase_whatever_the_keyring_says() {
    let dir = temp("shape-reopen");
    let keystore = passphrase_keystore(&dir, "passphrase-of-the-file");
    let sealer = keystore.for_namespace("vault");
    let sealed = sealer.seal("github|1", b"written-before-the-reopen").expect("seal");
    drop(sealer);
    drop(keystore);

    // No `with_protection`: the machine decides, and on Linux that decision is the kernel keyring's.
    // The file's own shape has to win, or the vault is unreadable on any host where the keyring answers.
    let reopened = Keystore::open(&Options::new(&dir).with_passphrase("passphrase-of-the-file"))
        .expect("a passphrase root file opens with its passphrase");
    assert_eq!(reopened.protection(), Protection::PassphraseFile);
    assert_eq!(reopened.note(), None, "the file agreed with nothing that needed naming");
    let reopened = std::sync::Arc::new(reopened);
    assert_eq!(
        reopened.for_namespace("vault").open("github|1", &sealed).expect("open").as_slice(),
        b"written-before-the-reopen"
    );
}

/// Requirement in one place: a refusal plus a passphrase is the sealed file and ONE named note; a refusal
/// without a passphrase is the refusal this keystore always answered.
#[cfg(not(windows))]
#[test]
fn a_keyring_refusal_is_a_note_with_a_passphrase_and_a_refusal_without_one() {
    let dir = temp("resolve");
    let (without, note) = resolve_protection_with(&Options::new(&dir), Err("edquot"));
    assert_eq!(without, Protection::PassphraseFile);
    assert_eq!(note, None, "no passphrase: the refusal must not be papered over");

    let (with, note) =
        resolve_protection_with(&Options::new(&dir).with_passphrase("p"), Err("edquot"));
    assert_eq!(with, Protection::PassphraseFile);
    assert_eq!(
        note.as_deref(),
        Some("keystore_keyring_refused:edquot, using the passphrase file")
    );

    let (usable, note) = resolve_protection_with(&Options::new(&dir).with_passphrase("p"), Ok(()));
    assert_eq!(usable, Protection::KernelKeyring);
    assert_eq!(note, None);

    // An operator's explicit choice is obeyed, refusal or not: `WASM_AGENT_VAULT_KEYSTORE` is a decision,
    // not a preference, and a typed protection must never be quietly swapped.
    let (forced, note) = resolve_protection_with(
        &Options::new(&dir).with_protection(Protection::KernelKeyring).with_passphrase("p"),
        Err("edquot"),
    );
    assert_eq!(forced, Protection::KernelKeyring);
    assert_eq!(note, None);
}

#[cfg(all(target_os = "linux", any(target_arch = "x86_64", target_arch = "aarch64")))]
mod keyring_probe {
    use super::*;

    /// The `add_key`/`keyctl` calls this test makes itself, so it can own a keyring it is allowed to
    /// break: a REFUSED keyring is the only way to get a real refusal out of the kernel without spending
    /// the machine's key quota on 200 junk entries.
    fn sys_add(kind: &str, name: &str, payload: &[u8], ring: i32) -> (i64, i32) {
        use std::ffi::CString;
        let kind = CString::new(kind).expect("static");
        let name = CString::new(name).expect("test name");
        let serial = unsafe {
            libc::syscall(
                248 as libc::c_long,
                kind.as_ptr() as libc::c_long,
                name.as_ptr() as libc::c_long,
                payload.as_ptr() as libc::c_long,
                payload.len() as libc::c_long,
                ring as libc::c_long,
            )
        };
        (serial, std::io::Error::last_os_error().raw_os_error().unwrap_or(0))
    }

    fn sys_keyctl(op: i32, arg: i32) -> i64 {
        unsafe {
            libc::syscall(
                250 as libc::c_long,
                op as libc::c_long,
                arg as libc::c_long,
                0 as libc::c_long,
                0 as libc::c_long,
                0 as libc::c_long,
            )
        }
    }

    /// A keyring that answers a real refusal: a private one, invalidated. When the machine's own key budget
    /// is already spent (the state wa-desktop was measured in, 200/200) the private keyring cannot be made
    /// and the user keyring refuses for the same reason — either way the caller gets a refusing ring.
    fn refused_ring() -> i32 {
        let name = format!("wa-keystore-test-ring-{}", std::process::id());
        let (serial, _) = sys_add("keyring", &name, b"", -3); // KEY_SPEC_SESSION_KEYRING
        if serial >= 0 {
            sys_keyctl(21, serial as i32); // KEYCTL_INVALIDATE
            return serial as i32;
        }
        keyring::user_keyring()
    }

    /// The probe must leave nothing charged behind. This is the defect that spent the uid's 200-key quota
    /// and made three rows fail inside the fast path while the same test passed alone: `KEYCTL_INVALIDATE`
    /// keeps the quota, so `/proc/keys` showed the entry as `I--Q---` for hours.
    #[test]
    fn the_availability_probe_leaves_nothing_charged() {
        let dirs: Vec<PathBuf> = (0..3).map(|i| temp(&format!("probe-{i}"))).collect();
        for dir in &dirs {
            // Either answer is a fact about this machine; what must not happen is an entry left behind.
            let _ = keyring::available(dir);
        }
        // The kernel returns a released entry's quota when it destroys the key, which it does a moment
        // after the unlink (measured: under two seconds; the same delay `wa vault` sees). So the
        // assertion is "gone, within a bound that is not the old behaviour's forever".
        for dir in &dirs {
            let name = format!("{}:", keyring::probe_description(dir));
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
            loop {
                let keys = std::fs::read_to_string("/proc/keys").unwrap_or_default();
                let charged = keys
                    .lines()
                    .filter(|line| line.split_whitespace().nth(8) == Some(name.as_str()))
                    .count();
                if charged == 0 {
                    break;
                }
                assert!(
                    std::time::Instant::now() < deadline,
                    "the probe left {charged} charged entr(y/ies) in the user keyring for {name}"
                );
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
    }

    /// The wrap-time half of the requirement, with a REAL refusal from the kernel: the probe passed a
    /// moment ago and the quota went since (the measured fast-path failure), or the keyring was lost. A
    /// passphrase makes that the sealed file with one note; without one the refusal is unchanged.
    #[test]
    fn a_refused_keyring_seals_with_the_passphrase_file_and_says_why() {
        let ring = refused_ring();
        let dir = temp("refused-ring");
        assert!(
            keyring::available_in(&dir, ring).is_err(),
            "this test needs a keyring that refuses, and {ring} did not"
        );

        let mut keystore = Keystore::open(
            &Options::new(&dir)
                .with_protection(Protection::KernelKeyring)
                .with_passphrase("fallback-passphrase"),
        )
        .expect("open")
        .with_ring(ring);
        let status = keystore.ensure_root().expect("a passphrase is configured, so the file takes over");
        assert_eq!(status.protection, Protection::PassphraseFile, "status must report what the file is");
        let note = keystore.note().expect("exactly one note").to_string();
        assert!(note.starts_with("keystore_keyring_refused:"), "note={note}");
        assert!(note.ends_with("using the passphrase file"), "note={note}");
        assert_eq!(
            std::fs::read(dir.join(ROOT_FILE)).expect("root file").len(),
            PASSPHRASE_ROOT_LEN,
            "the file written must be the passphrase shape, so the next process reads it as one"
        );
        // And it is a working keystore, not just a file: seal under it and open it again.
        let keystore = std::sync::Arc::new(keystore);
        let sealed = keystore.for_namespace("vault").seal("k|1", b"v").expect("seal");
        assert_eq!(keystore.for_namespace("vault").open("k|1", &sealed).expect("open").as_slice(), b"v");

        // The half that must never weaken: no passphrase, same refusal, and nothing written.
        let strict_dir = temp("refused-ring-strict");
        let mut strict = Keystore::open(
            &Options::new(&strict_dir).with_protection(Protection::KernelKeyring),
        )
        .expect("open")
        .with_ring(ring);
        assert_eq!(
            strict.ensure_root().unwrap_err().reason(),
            "keystore_keyring_unavailable",
            "without a passphrase the answer stays exactly what it was"
        );
        assert_eq!(strict.note(), None, "a refusal is an error, not a note");
        assert!(!strict_dir.join(ROOT_FILE).exists(), "nothing may be written without a keystore");
    }
}
