//! Check one exported `dev.json` against the real device record the Rust client reads.
//!
//! `node scripts/whatsapp-adopt.mjs export` writes the JSON from a copy of a whatsmeow store; this
//! binary is the proof that the bytes deserialize into `wacore::store::Device` and that every public
//! key in it is the one its private key derives. It prints non-secret facts only: the JIDs, the
//! registration id, the signed-pre-key id, whether the ADV account is present, and the private key
//! lengths. It never prints key material and never connects.
//!
//!     cargo run --example adopt_check -- <dev.json>
use wacore::store::Device;

fn main() {
    let path = match std::env::args().nth(1) {
        Some(path) => path,
        None => {
            eprintln!("usage: adopt_check <dev.json>");
            std::process::exit(2);
        }
    };
    let bytes = std::fs::read(&path).unwrap_or_else(|error| {
        eprintln!("read {path}: {error}");
        std::process::exit(2);
    });
    let device: Device = serde_json::from_slice(&bytes).unwrap_or_else(|error| {
        eprintln!("not a wacore device record: {error}");
        std::process::exit(1);
    });
    let mut problems = Vec::new();
    if device.pn.is_none() {
        problems.push("pn is absent");
    }
    if device.registration_id == 0 {
        problems.push("registration_id is zero");
    }
    if device.account.is_none() {
        problems.push("the ADV account is absent (a send would have no device identity)");
    }
    for (name, pair) in [
        ("noise_key", &device.noise_key),
        ("identity_key", &device.identity_key),
        ("signed_pre_key", &device.signed_pre_key),
    ] {
        match pair.private_key.public_key() {
            Ok(public) if public.public_key_bytes() == pair.public_key.public_key_bytes() => {}
            Ok(_) => problems.push("a stored public key is not the one its private key derives"),
            Err(_) => problems.push("a private key is unreadable"),
        }
        let _ = name;
    }
    if !problems.is_empty() {
        eprintln!("device rejected: {}", problems.join("; "));
        std::process::exit(1);
    }
    println!(
        "device ok pn={} lid={} registration_id={} signed_pre_key_id={} account={} push_name_len={}",
        device.pn.as_ref().map(ToString::to_string).unwrap_or_default(),
        device.lid.as_ref().map(ToString::to_string).unwrap_or_default(),
        device.registration_id,
        device.signed_pre_key_id,
        device.account.is_some(),
        device.push_name.chars().count(),
    );
}
