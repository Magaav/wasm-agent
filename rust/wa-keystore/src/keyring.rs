//! The Linux kernel keyring as the store for the *wrapping* key (`add_key`/`keyctl`, user keyring).
//!
//! A user keyring is per-user, in-kernel, and never written to a file: the payload is not readable
//! from `/proc` and it disappears when the session's keys are cleared, which is exactly the lifetime
//! wanted for "the wrapping key exists while the node runs". The root data key is still stored
//! XChaCha20-Poly1305-sealed in `root-key.wrap`; the keyring only holds the key that opens it, so
//! neither the file alone nor the keyring alone is the vault root.
//!
//! Where there is no keyring (containers with a restricted `add_key`, an old kernel, a systemd unit
//! with a private keyring the process cannot reach) this module answers a [`Refusal`] and the keystore
//! falls back to the Argon2id passphrase file — reported as `protection: passphrase`, never silently.
//!
//! **The keyring is shared, quota-limited machine state, and every entry costs.** The user keyring is
//! per uid, not per process or per test, and the kernel charges it a hard budget (`kernel.keys.maxkeys`
//! 200 and `maxbytes` 20000 for a non-root user). Measured on wa-desktop (13/11, 6.6.87.2-microsoft-
//! standard): the uid stood at 200/200 charged keys after a day of runs, 102 of them `wa-keystore-probe`
//! entries this module had already invalidated, and `add_key` answered EDQUOT — which the keystore
//! reported as `keystore_keyring_unavailable`. Two rules follow, and both are load-bearing:
//!
//!  * an entry this module creates for a *probe* is [released](release), never merely invalidated, because
//!    `KEYCTL_INVALIDATE` keeps the quota charged (the entry shows as `I--Q---` for hours);
//!  * the keystore asks this module for a keyring entry only when it is creating a new root key, and a
//!    real refusal is a value the caller can act on (fall back to the passphrase file), not a panic and
//!    not a silent false.
//!
//! The syscall numbers are per architecture because `libc` does not export `SYS_add_key` for every
//! target this repo builds. Only x86_64 and aarch64 are wired; anything else refuses in the same words
//! as an absent keyring.
use ring::rand::SecureRandom;
use std::ffi::CString;
use zeroize::Zeroizing;

/// `KEY_SPEC_USER_KEYRING` from `linux/keyctl.h`.
const KEY_SPEC_USER_KEYRING: i32 = -4;
/// `KEYCTL_SEARCH`.
const KEYCTL_SEARCH: i32 = 10;
/// `KEYCTL_READ`.
const KEYCTL_READ: i32 = 11;
/// `KEYCTL_UNLINK`.
const KEYCTL_UNLINK: i32 = 9;

#[cfg(target_arch = "x86_64")]
const SYS_ADD_KEY: libc::c_long = 248;
#[cfg(target_arch = "x86_64")]
const SYS_KEYCTL: libc::c_long = 250;
#[cfg(target_arch = "aarch64")]
const SYS_ADD_KEY: libc::c_long = 217;
#[cfg(target_arch = "aarch64")]
const SYS_KEYCTL: libc::c_long = 219;

/// A real refusal from the kernel keyring, named by its errno.
///
/// This is a *value*, not an error string, because the caller has a decision to make with it: the
/// keystore falls back to the passphrase file on a refusal when one is configured, and answers the same
/// `keystore_keyring_unavailable` refusal it always answered when none is (`docs/VAULT.md`). The name
/// travels into the one note an operator sees, so "the keyring refused" says *why*.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Refusal(&'static str);

impl Refusal {
    /// The errno, in the lowercase words a note uses: `edquot`, `eperm`, `eacces`, `ekeyrevoked`, …
    pub(crate) fn name(&self) -> &'static str {
        self.0
    }

    /// Build a refusal from the errno `keyctl`/`add_key` left behind.
    pub(crate) fn from_errno(code: i32) -> Refusal {
        Refusal(match code {
            1 => "eperm",
            12 => "enomem",
            13 => "eacces",
            38 => "enosys",
            // The uid's key budget (`kernel.keys.maxkeys`/`maxbytes`). The one measured on wa-desktop,
            // and the one that made three vault tests fail inside the fast path while passing alone.
            122 => "edquot",
            127 => "ekeyexpired",
            128 => "ekeyrevoked",
            _ => "refused",
        })
    }

    /// A key that exists under our name but is not a 32-byte wrapping key: another process wrote it, or
    /// an older build did. Refusing keeps the caller from deriving a key from a truncated payload.
    fn bad_payload() -> Refusal {
        Refusal("bad_payload")
    }

    /// The entry was written and could not be read back. The full round trip is the question (see
    /// [`available_in`]), so this is a refusal to *use* the keyring rather than a failure of the call.
    fn not_read_back() -> Refusal {
        Refusal("not_read_back")
    }

    fn entropy() -> Refusal {
        Refusal("entropy")
    }

    /// This build has no syscall numbers for this architecture.
    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    fn unsupported() -> Refusal {
        Refusal("unsupported")
    }
}

/// The keyring entry name. One per keystore directory, so two vaults on one host do not share a
/// wrapping key.
fn description(dir: &std::path::Path) -> String {
    use ring::digest;
    let canonical = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
    let digest = digest::digest(&digest::SHA256, canonical.to_string_lossy().as_bytes());
    let hex: String = digest.as_ref()[..8].iter().map(|byte| format!("{byte:02x}")).collect();
    format!("wa-keystore-v1:{hex}")
}

/// The keyring the keystore uses by default: the user's, which outlives one process (`wa vault set` in
/// one process, `wa vault reveal` in the next). Fixed rather than configurable on purpose — a knob here
/// would be a knob for "where the wrapping key lives", and the answer is not an operator preference.
#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
pub(crate) fn user_keyring() -> i32 {
    KEY_SPEC_USER_KEYRING
}

/// Read the wrapping key for `dir` from `ring`, creating it when it is absent.
pub(crate) fn wrapping_key_in(
    dir: &std::path::Path,
    ring: i32,
) -> Result<Zeroizing<[u8; 32]>, Refusal> {
    let name = description(dir);
    if let Some(key) = read_in(ring, &name)? {
        return Ok(key);
    }
    let mut key = Zeroizing::new([0u8; 32]);
    ring::rand::SystemRandom::new().fill(key.as_mut()).map_err(|_| Refusal::entropy())?;
    add_in(ring, &name, key.as_ref())?;
    // Another process may have created the same entry between the search and the add; read it back so
    // both processes end up on one key rather than one of them sealed under a key it no longer has.
    read_in(ring, &name)?.ok_or_else(Refusal::not_read_back)
}

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
pub(crate) fn available(dir: &std::path::Path) -> Result<(), Refusal> {
    available_in(dir, user_keyring())
}

/// Whether opening a keystore should use this protection.
///
/// The question is not "can I reach a keyring" but "does a full write-and-read-back work", because
/// that is what the keystore does with its wrapping key (`wrapping_key`). Measured on WSL2
/// (6.6.87.2-microsoft-standard, 11/11): `add_key` answers a serial and `keyctl READ` answers EACCES, so
/// a search-only probe said "keyring" and the first `wa vault` command on the machine died
/// `keystore_keyring_bad_payload` instead of taking the passphrase fallback this function exists to
/// choose. A probe entry under its own name (never the wrapping key's) is written, read back and
/// RELEASED, so answering costs nothing that outlives the call — measured: `KEYCTL_INVALIDATE` left the
/// entry charged (`I--Q---`, 199/200 keys still charged afterwards) while `KEYCTL_UNLINK` gave the quota
/// back, so this is an [`release`] and not an invalidate.
pub(crate) fn available_in(dir: &std::path::Path, ring: i32) -> Result<(), Refusal> {
    let name = probe_description(dir);
    if search_in(ring, &name)?.is_some() {
        // An entry from a process that died between add and release: reading it back is the same proof.
        return read_in(ring, &name).map(|_| ());
    }
    let mut payload = Zeroizing::new([0u8; 32]);
    ring::rand::SystemRandom::new().fill(payload.as_mut()).map_err(|_| Refusal::entropy())?;
    add_in(ring, &name, payload.as_ref())?;
    let readable = read_in(ring, &name).map(|_| ());
    release(ring, &name);
    readable
}

/// The name of the availability probe. Never the wrapping key's name: a probe that reused it would
/// create the very key it is asking about, and `wa vault status` would have a side effect.
pub(crate) fn probe_description(dir: &std::path::Path) -> String {
    format!("wa-keystore-probe-v1:{}", description(dir).rsplit(':').next().unwrap_or("0"))
}

/// Drop the probe entry so a status check leaves the keyring as it found it, and so the uid's key quota
/// is given back.
///
/// `KEYCTL_INVALIDATE` is what this used to do and it does **not** return the entry's quota. Measured on
/// wa-desktop (13/11, `kernel.keys.maxkeys` 200): with the uid at 199/200 charged, the invalidate
/// returned 0, `/proc/key-users` still said 199, the next `add_key` answered EDQUOT, and `/proc/keys`
/// listed the entry as `I--Q---` (invalidated, still charged) hours later — 102 such probe entries were
/// in the ring. `KEYCTL_UNLINK` removes the last link, the key is destroyed and the charge with it
/// (measured: 189 unlinked keys took the uid from 200/200 back to 5/200 in under two seconds).
///
/// A refusal here is not a failure: the entry is 32 random bytes this process never uses again.
#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
fn release(ring: i32, name: &str) {
    let Ok(Some(serial)) = search_in(ring, name) else {
        return;
    };
    // SAFETY: `keyctl(UNLINK, serial, ring, 0, 0)` takes the serial found above and the keyring it was
    // found in, and no pointers at all.
    unsafe {
        libc::syscall(
            SYS_KEYCTL,
            KEYCTL_UNLINK as libc::c_long,
            serial as libc::c_long,
            ring as libc::c_long,
            0 as libc::c_long,
            0 as libc::c_long,
        );
    }
}

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
fn search_in(ring: i32, name: &str) -> Result<Option<i32>, Refusal> {
    let name = CString::new(name).map_err(|_| Refusal::bad_payload())?;
    let kind = CString::new("user").expect("static");
    // SAFETY: `keyctl` with SEARCH takes (option, arg2=keyring, arg3=type, arg4=description,
    // arg5=dest keyring); all pointers are valid NUL-terminated strings for the call.
    let serial = unsafe {
        libc::syscall(
            SYS_KEYCTL,
            KEYCTL_SEARCH as libc::c_long,
            ring as libc::c_long,
            kind.as_ptr() as libc::c_long,
            name.as_ptr() as libc::c_long,
            0 as libc::c_long,
        )
    };
    if serial >= 0 {
        return Ok(Some(serial as i32));
    }
    let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
    // ENOKEY (126): no such key — the ordinary "nothing stored yet". Anything else is a real refusal
    // (EPERM in a restricted container, EDQUOT when the uid's key quota is spent).
    match errno {
        126 => Ok(None),
        other => Err(Refusal::from_errno(other)),
    }
}

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
fn read_in(ring: i32, name: &str) -> Result<Option<Zeroizing<[u8; 32]>>, Refusal> {
    let Some(serial) = search_in(ring, name)? else {
        return Ok(None);
    };
    let mut buffer = Zeroizing::new([0u8; 32]);
    // SAFETY: `keyctl(READ, serial, buf, buflen, 0)` writes at most `buflen` bytes into `buffer`,
    // which is a live 32-byte array for the duration of the call.
    let read = unsafe {
        libc::syscall(
            SYS_KEYCTL,
            KEYCTL_READ as libc::c_long,
            serial as libc::c_long,
            buffer.as_mut().as_mut_ptr() as libc::c_long,
            buffer.len() as libc::c_long,
            0 as libc::c_long,
        )
    };
    if read < 0 {
        return Err(Refusal::from_errno(std::io::Error::last_os_error().raw_os_error().unwrap_or(0)));
    }
    if read != 32 {
        // A key of another length is not ours: refuse rather than derive from a truncated payload.
        return Err(Refusal::bad_payload());
    }
    Ok(Some(buffer))
}

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
fn add_in(ring: i32, name: &str, payload: &[u8]) -> Result<(), Refusal> {
    let name = CString::new(name).map_err(|_| Refusal::bad_payload())?;
    let kind = CString::new("user").expect("static");
    // SAFETY: `add_key` reads `plen` bytes from `payload` and NUL-terminated strings from `kind`/
    // `name`, all alive for the call.
    let serial = unsafe {
        libc::syscall(
            SYS_ADD_KEY,
            kind.as_ptr() as libc::c_long,
            name.as_ptr() as libc::c_long,
            payload.as_ptr() as libc::c_long,
            payload.len() as libc::c_long,
            ring as libc::c_long,
        )
    };
    if serial >= 0 {
        return Ok(());
    }
    // EEXIST is the race above, and is not a failure: the caller re-reads the entry.
    match std::io::Error::last_os_error().raw_os_error().unwrap_or(0) {
        17 => Ok(()),
        other => Err(Refusal::from_errno(other)),
    }
}

#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
pub(crate) fn user_keyring() -> i32 {
    0
}

#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
pub(crate) fn wrapping_key_in(
    _dir: &std::path::Path,
    _ring: i32,
) -> Result<Zeroizing<[u8; 32]>, Refusal> {
    Err(Refusal::unsupported())
}

#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
pub(crate) fn available(_dir: &std::path::Path) -> Result<(), Refusal> {
    Err(Refusal::unsupported())
}

#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
pub(crate) fn available_in(_dir: &std::path::Path, _ring: i32) -> Result<(), Refusal> {
    Err(Refusal::unsupported())
}
