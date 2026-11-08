//! The two primitives the keystore itself needs: XChaCha20-Poly1305 over a 32-byte key, and an
//! Argon2id-derived key for the passphrase fallback.
//!
//! The blob format is explicit so it can be read a year from now without guessing:
//!
//! ```text
//! 0x01 || nonce[24] || ciphertext+tag
//! ```
//!
//! The version byte is the whole forward-compatibility plan: a format change writes `0x02` and the
//! reader refuses the unknown byte rather than trying the wrong cipher on the right bytes.
use chacha20poly1305::aead::{AeadInPlace, KeyInit};
use ring::rand::SecureRandom;
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use zeroize::Zeroizing;

use crate::{Error, Result};

/// The one blob version this build writes and reads.
const BLOB_VERSION: u8 = 1;

pub(crate) fn seal_with(key: &[u8; 32], context: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
    let cipher = XChaCha20Poly1305::new(Key::from_slice(key));
    let mut nonce = [0u8; 24];
    ring::rand::SystemRandom::new()
        .fill(&mut nonce)
        .map_err(|_| Error::bad("keystore_entropy_unavailable"))?;
    let mut buffer = plaintext.to_vec();
    cipher
        .encrypt_in_place(XNonce::from_slice(&nonce), context, &mut buffer)
        .map_err(|_| Error::bad("sealed_blob_failed"))?;
    let mut blob = Vec::with_capacity(1 + nonce.len() + buffer.len());
    blob.push(BLOB_VERSION);
    blob.extend_from_slice(&nonce);
    blob.extend_from_slice(&buffer);
    Ok(blob)
}

pub(crate) fn open_with(key: &[u8; 32], context: &[u8], blob: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    let version = *blob.first().ok_or_else(|| Error::bad("sealed_blob_corrupt"))?;
    if version != BLOB_VERSION {
        return Err(Error::bad("sealed_blob_version_unknown"));
    }
    if blob.len() < 1 + 24 + 16 {
        return Err(Error::bad("sealed_blob_corrupt"));
    }
    let nonce = &blob[1..25];
    let cipher = XChaCha20Poly1305::new(Key::from_slice(key));
    let mut buffer = Zeroizing::new(blob[25..].to_vec());
    cipher
        .decrypt_in_place(XNonce::from_slice(nonce), context, &mut *buffer)
        .map_err(|_| Error::bad("sealed_blob_refused"))?;
    Ok(buffer)
}

/// Argon2id over an operator passphrase. The parameters are the low-memory/strong-time point of the
/// public guidance (64 MiB, 3 passes, one lane): a passphrase is the weakest protection here, so it
/// gets the most work a person will still wait for during one `wa vault` command.
pub(crate) fn argon2id_key(passphrase: &[u8], salt: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
    use argon2::{Algorithm, Argon2, Params, Version};
    let params = Params::new(64 * 1024, 3, 1, Some(32))
        .map_err(|error| Error::bad(format!("keystore_params: {error}")))?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut key = Zeroizing::new([0u8; 32]);
    argon
        .hash_password_into(passphrase, salt, key.as_mut())
        .map_err(|error| Error::bad(format!("keystore_kdf: {error}")))?;
    Ok(key)
}
