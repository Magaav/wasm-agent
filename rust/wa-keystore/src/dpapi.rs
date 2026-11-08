//! Windows DPAPI, **user** scope (`CryptProtectData`/`CryptUnprotectData`).
//!
//! The wrapping key DPAPI uses is derived from the logged-on user's master key: the blob cannot be
//! unwrapped by another account, on another machine, or after a password reset that rotates the
//! master key without the user's old credentials. That is the strongest boundary available here
//! without a TPM, and it needs no passphrase and no daemon.
//!
//! `CRYPTPROTECT_UI_FORBIDDEN` is not cosmetic: without it DPAPI is allowed to raise a prompt, and a
//! node that blocks on a window for a keystore unwrap is a node that hangs in a service context.
//!
//! The optional entropy is the domain string (`wa-keystore-v1`), so a DPAPI blob this module produced
//! for one purpose cannot be unwrapped by code that only has the account.
use super::{Error, Result};
use std::ptr;
use windows_sys::Win32::Foundation::LocalFree;
use windows_sys::Win32::Security::Cryptography::{
    CryptProtectData, CryptUnprotectData, CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN,
};

pub(crate) fn protect(entropy: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
    call(true, entropy, plaintext)
}

pub(crate) fn unprotect(entropy: &[u8], blob: &[u8]) -> Result<Vec<u8>> {
    call(false, entropy, blob)
}

fn call(protect: bool, entropy: &[u8], data: &[u8]) -> Result<Vec<u8>> {
    let input = CRYPT_INTEGER_BLOB { cbData: data.len() as u32, pbData: data.as_ptr() as *mut u8 };
    let entropy_blob =
        CRYPT_INTEGER_BLOB { cbData: entropy.len() as u32, pbData: entropy.as_ptr() as *mut u8 };
    let mut output = CRYPT_INTEGER_BLOB { cbData: 0, pbData: ptr::null_mut() };
    // SAFETY: both input blobs borrow live slices for the duration of the call, `output` is a live
    // local the API owns, and the prompt/description pointers are NULL with the UI forbidden, so DPAPI
    // never writes through them. `pbData` of the answer is freed with `LocalFree` exactly once.
    let ok = unsafe {
        if protect {
            CryptProtectData(
                &input,
                ptr::null(),
                &entropy_blob,
                ptr::null(),
                ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &input,
                ptr::null_mut(),
                &entropy_blob,
                ptr::null(),
                ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        }
    };
    if ok == 0 {
        return Err(Error::bad(if protect {
            "keystore_dpapi_protect_failed"
        } else {
            "keystore_dpapi_unprotect_failed"
        }
        .to_string()));
    }
    if output.pbData.is_null() {
        return Err(Error::bad("keystore_dpapi_empty"));
    }
    // SAFETY: DPAPI returned a buffer of `cbData` bytes at `pbData`; it is read once and freed here.
    let bytes = unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
    unsafe {
        LocalFree(output.pbData as *mut core::ffi::c_void);
    }
    Ok(bytes)
}
