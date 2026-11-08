//! The Linux kernel keyring as the store for the *wrapping* key (`add_key`/`keyctl`, user keyring).
//!
//! A user keyring is per-user, in-kernel, and never written to a file: the payload is not readable
//! from `/proc` and it disappears when the session's keys are cleared, which is exactly the lifetime
//! wanted for "the wrapping key exists while the node runs". The root data key is still stored
//! XChaCha20-Poly1305-sealed in `root-key.wrap`; the keyring only holds the key that opens it, so
//! neither the file alone nor the keyring alone is the vault root.
//!
//! Where there is no keyring (containers with a restricted `add_key`, an old kernel, a systemd unit
//! with a private keyring the process cannot reach) this module answers an error and the keystore
//! falls back to the Argon2id passphrase file — reported as `protection: passphrase`, never silently.
//!
//! The syscall numbers are per architecture because `libc` does not export `SYS_add_key` for every
//! target this repo builds. Only x86_64 and aarch64 are wired; anything else falls back.
use super::{Error, Result};
use std::ffi::CString;
use zeroize::Zeroizing;

/// `KEY_SPEC_USER_KEYRING` from `linux/keyctl.h`.
const KEY_SPEC_USER_KEYRING: i32 = -4;
/// `KEYCTL_SEARCH`.
const KEYCTL_SEARCH: i32 = 10;
/// `KEYCTL_READ`.
const KEYCTL_READ: i32 = 11;

#[cfg(target_arch = "x86_64")]
const SYS_ADD_KEY: libc::c_long = 248;
#[cfg(target_arch = "x86_64")]
const SYS_KEYCTL: libc::c_long = 250;
#[cfg(target_arch = "aarch64")]
const SYS_ADD_KEY: libc::c_long = 217;
#[cfg(target_arch = "aarch64")]
const SYS_KEYCTL: libc::c_long = 219;

/// The keyring entry name. One per keystore directory, so two vaults on one host do not share a
/// wrapping key.
fn description(dir: &std::path::Path) -> String {
    use ring::digest;
    let canonical = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
    let digest = digest::digest(&digest::SHA256, canonical.to_string_lossy().as_bytes());
    let hex: String = digest.as_ref()[..8].iter().map(|byte| format!("{byte:02x}")).collect();
    format!("wa-keystore-v1:{hex}")
}

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
pub(crate) fn wrapping_key(dir: &std::path::Path) -> Result<Zeroizing<[u8; 32]>> {
    let name = description(dir);
    if let Some(key) = read_key(&name)? {
        return Ok(key);
    }
    let mut key = Zeroizing::new([0u8; 32]);
    ring::rand::SystemRandom::new()
        .fill(key.as_mut())
        .map_err(|_| Error::bad("keystore_entropy_unavailable"))?;
    add_key(&name, key.as_ref())?;
    // Another process may have created the same entry between the search and the add; read it back so
    // both processes end up on one key rather than one of them sealed under a key it no longer has.
    read_key(&name)?.ok_or_else(|| Error::bad("keystore_keyring_unavailable"))
}

#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
pub(crate) fn wrapping_key(_dir: &std::path::Path) -> Result<Zeroizing<[u8; 32]>> {
    Err(Error::bad("keystore_protection_unavailable:keyring"))
}

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
fn user_keyring() -> i32 {
    KEY_SPEC_USER_KEYRING
}

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
fn search(name: &str) -> Result<Option<i32>> {
    let name = CString::new(name).map_err(|_| Error::bad("keystore_keyring_name"))?;
    let kind = CString::new("user").expect("static");
    // SAFETY: `keyctl` with SEARCH takes (option, arg2=keyring, arg3=type, arg4=description,
    // arg5=dest keyring); all pointers are valid NUL-terminated strings for the call.
    let serial = unsafe {
        libc::syscall(
            SYS_KEYCTL,
            KEYCTL_SEARCH as libc::c_long,
            user_keyring() as libc::c_long,
            kind.as_ptr() as libc::c_long,
            name.as_ptr() as libc::c_long,
            0 as libc::c_long,
        )
    };
    if serial >= 0 {
        return Ok(Some(serial as i32));
    }
    let errno = std::io::Error::last_os_error();
    match errno.raw_os_error() {
        // ENOKEY: no such key. Anything else is a real refusal (EPERM in a restricted container).
        Some(126) => Ok(None),
        _ => Err(Error::bad("keystore_keyring_unavailable")),
    }
}

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
fn read_key(name: &str) -> Result<Option<Zeroizing<[u8; 32]>>> {
    let Some(serial) = search(name)? else {
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
    if read != 32 {
        // A key of another length is not ours: refuse rather than derive from a truncated payload.
        return Err(Error::bad("keystore_keyring_bad_payload"));
    }
    Ok(Some(buffer))
}

#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
fn add_key(name: &str, payload: &[u8]) -> Result<()> {
    let name = CString::new(name).map_err(|_| Error::bad("keystore_keyring_name"))?;
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
            user_keyring() as libc::c_long,
        )
    };
    if serial >= 0 {
        return Ok(());
    }
    // EEXIST is the race above, and is not a failure: the caller re-reads the entry.
    match std::io::Error::last_os_error().raw_os_error() {
        Some(17) => Ok(()),
        _ => Err(Error::bad("keystore_keyring_unavailable")),
    }
}

/// Whether opening a keystore should use this protection. A search that answers ENOKEY before the
/// entry is created means the keyring is reachable; any other refusal means it is not.
#[cfg(any(target_arch = "x86_64", target_arch = "aarch64"))]
pub(crate) fn available(dir: &std::path::Path) -> bool {
    search(&description(dir)).is_ok()
}

#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
pub(crate) fn available(_dir: &std::path::Path) -> bool {
    false
}
