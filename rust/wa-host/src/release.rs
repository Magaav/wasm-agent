//! Signed releases: verify a release's `SHA256SUMS.sig` before this node installs any of its assets.
//!
//! WHY. A node used to check a download against `SHA256SUMS` from the SAME release, so whoever could
//! publish a release could swap the binary and the checksum together and every check would still pass. The
//! release signing key lives in wa-vault (`release-signing`, ed25519): the vault signs the sums and never
//! returns the key, and this module verifies the signature against a public key the node holds before the
//! release - `config/release-keys.txt`, embedded in this binary at compile time, plus the node's own copy.
//!
//! The files, which `scripts/lib/release_verify.py` reads on the hosts that have no `wa` binary yet:
//!
//! ```text
//! SHA256SUMS.sig                 TRUSTED-KEYS                TRUSTED-KEYS.sig
//! wa-release-signature v1        wa-trusted-keys v1          (the same shape as SHA256SUMS.sig)
//! key <key id>                   key <key id> <public hex>
//! alg ed25519                    key <key id> <public hex>
//! sha256 <hex of the file>
//! sig <hex, 64 bytes>
//! ```
//!
//! What is signed is the SHA-256 DIGEST of the file named on the `sha256` line (32 bytes), not its text:
//! the vault signs a digest (`POST /api/release-signing/sign {sha256}`) and a node recomputes it over the
//! bytes it downloaded, so the two never have to agree about a file's framing.
//!
//! ROTATION. A release may announce a new key in `TRUSTED-KEYS`, signed (`TRUSTED-KEYS.sig`) by a key that
//! is trusted NOW - the embedded/config list, never the announced one. Only then is the announced list the
//! trust set for that release's sums, so a rotation signed by an unknown key is refused and one announced
//! by a trusted key is accepted even when the release itself is signed by the new key.
//!
//! Both implementations are judged by the same fixtures (`tests/fixtures/release-sign/`), produced by the
//! vault's own signer, so they cannot agree only with each other. The rules are exercised here
//! (`#[cfg(test)]` below) and from the shell (`scripts/test-release-signing.sh`).
use std::path::{Path, PathBuf};

pub const SIGNATURE_HEADER: &str = "wa-release-signature v1";
pub const TRUST_HEADER: &str = "wa-trusted-keys v1";

/// The keys this binary was built with. Empty until the operator creates the release key
/// (`config/release-keys.txt` says why that refusal is the feature).
const EMBEDDED_TRUSTED_KEYS: &str = include_str!("../../../config/release-keys.txt");

const SIGNATURE_FILE: &str = "SHA256SUMS.sig";
const SUMS_FILE: &str = "SHA256SUMS";
const ANNOUNCEMENT_FILE: &str = "TRUSTED-KEYS";

/// One trusted ed25519 key. `public` is 32 bytes, decoded once, so a malformed line is refused at load.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Key {
    pub id: String,
    pub public: Vec<u8>,
}

/// A parsed signature file. `signature` is 64 bytes; `sha256` is the digest it is about.
#[derive(Debug, Clone)]
pub struct Signature {
    pub key: String,
    pub sha256: Vec<u8>,
    pub signature: Vec<u8>,
}

/// A refusal, with the code the shell side uses too: 2 no signature, 3 about other bytes, 4 key not
/// trusted, 5 a rotation announcement not vouched for, 6 unreadable or malformed.
#[derive(Debug, Clone)]
pub struct ReleaseError {
    pub code: i32,
    pub message: String,
}

impl ReleaseError {
    fn new(code: i32, message: impl Into<String>) -> Self {
        ReleaseError { code, message: message.into() }
    }
}

impl std::fmt::Display for ReleaseError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn hex_decode(text: &str) -> Option<Vec<u8>> {
    let text = text.trim();
    if !text.is_ascii() || !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len() / 2).map(|index| u8::from_str_radix(&text[index * 2..index * 2 + 2], 16).ok()).collect()
}

fn sha256(bytes: &[u8]) -> Vec<u8> {
    ring::digest::digest(&ring::digest::SHA256, bytes).as_ref().to_vec()
}

fn ed25519_verify(public: &[u8], message: &[u8], signature: &[u8]) -> bool {
    if public.len() != 32 || signature.len() != 64 {
        return false;
    }
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, public)
        .verify(message, signature)
        .is_ok()
}

/// `wa-trusted-keys v1` + one `key <id> <public hex>` line each. A malformed line is a refusal, not a
/// line to skip: a key file a reader partly understands is a key file that trusts something else.
pub fn parse_trusted_keys(text: &str, source: &str) -> Result<Vec<Key>, ReleaseError> {
    let mut keys: Vec<Key> = Vec::new();
    let mut header = false;
    for (number, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if !header {
            if line != TRUST_HEADER {
                return Err(ReleaseError::new(6, format!("{source}: line {} is not '{TRUST_HEADER}'", number + 1)));
            }
            header = true;
            continue;
        }
        let fields: Vec<&str> = line.split_whitespace().collect();
        let public = fields.get(2).and_then(|value| hex_decode(value)).filter(|bytes| bytes.len() == 32);
        let (Some("key"), Some(id), Some(public)) = (fields.first().copied(), fields.get(1), public) else {
            return Err(ReleaseError::new(6, format!("{source}: line {} is not 'key <id> <public hex>'", number + 1)));
        };
        if !keys.iter().any(|key| key.id == *id) {
            keys.push(Key { id: (*id).to_string(), public });
        }
    }
    if !header {
        return Err(ReleaseError::new(6, format!("{source}: no '{TRUST_HEADER}' header")));
    }
    Ok(keys)
}

/// A `wa-release-signature v1` file. Every field is required; `alg` must be ed25519.
pub fn parse_signature(text: &str, source: &str) -> Result<Signature, ReleaseError> {
    let mut header = false;
    let mut key: Option<&str> = None;
    let mut alg: Option<&str> = None;
    let mut digest: Option<&str> = None;
    let mut signature: Option<&str> = None;
    for (number, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if !header {
            if line != SIGNATURE_HEADER {
                return Err(ReleaseError::new(6, format!("{source}: line {} is not '{SIGNATURE_HEADER}'", number + 1)));
            }
            header = true;
            continue;
        }
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() != 2 {
            return Err(ReleaseError::new(6, format!("{source}: line {} is not '<field> <value>'", number + 1)));
        }
        match fields[0] {
            "key" => key = Some(fields[1]),
            "alg" => alg = Some(fields[1]),
            "sha256" => digest = Some(fields[1]),
            "sig" => signature = Some(fields[1]),
            other => {
                return Err(ReleaseError::new(6, format!("{source}: line {} names an unknown field '{other}'", number + 1)))
            }
        }
    }
    if !header {
        return Err(ReleaseError::new(6, format!("{source}: no '{SIGNATURE_HEADER}' header")));
    }
    let (Some(key), Some(alg), Some(digest), Some(signature)) = (key, alg, digest, signature) else {
        return Err(ReleaseError::new(6, format!("{source}: key, alg, sha256 and sig are all required")));
    };
    if alg != "ed25519" {
        return Err(ReleaseError::new(6, format!("{source}: algorithm '{alg}' is not ed25519")));
    }
    let (Some(sha256), Some(signature)) = (hex_decode(digest), hex_decode(signature)) else {
        return Err(ReleaseError::new(6, format!("{source}: sha256 and sig must be hex")));
    };
    if sha256.len() != 32 || signature.len() != 64 {
        return Err(ReleaseError::new(6, format!("{source}: sha256 must be 32 bytes and sig 64")));
    }
    Ok(Signature { key: key.to_string(), sha256, signature })
}

/// Where this node trusts release keys from, in the order that matters: the binary's own list, the node's
/// copy, then whatever `WA_RELEASE_KEYS` names (a test, or a hand-run check).
pub fn key_files(extra: &[PathBuf]) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = Vec::new();
    let home = std::env::var("WASM_AGENT_HOME").ok().filter(|value| !value.is_empty());
    if let Some(home) = home {
        files.push(PathBuf::from(home).join("release-keys.txt"));
    }
    if let Ok(listed) = std::env::var("WA_RELEASE_KEYS") {
        files.extend(listed.split([':', ';']).filter(|one| !one.is_empty()).map(PathBuf::from));
    }
    files.extend(extra.iter().cloned());
    files
}

/// Every key trusted here: the embedded list plus each existing file. A malformed file is a refusal.
pub fn trusted_keys(extra: &[PathBuf]) -> Result<Vec<Key>, ReleaseError> {
    let mut keys = parse_trusted_keys(EMBEDDED_TRUSTED_KEYS, "the keys embedded in this binary")?;
    for path in key_files(extra) {
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(ReleaseError::new(6, format!("{}: {error}", path.display())));
            }
        };
        for key in parse_trusted_keys(&text, &path.display().to_string())? {
            if !keys.iter().any(|known| known.id == key.id) {
                keys.push(key);
            }
        }
    }
    Ok(keys)
}

fn read(path: &Path) -> Result<Vec<u8>, ReleaseError> {
    std::fs::read(path).map_err(|error| ReleaseError::new(6, format!("{}: {error}", path.display())))
}

/// The keys a refusal names as trusted, and the plain sentence for the case that is nobody.
fn trusted_key_list(trusted: &[Key]) -> String {
    if trusted.is_empty() {
        "no trusted key is configured".to_string()
    } else {
        trusted.iter().map(|key| key.id.as_str()).collect::<Vec<&str>>().join(", ")
    }
}

/// Verify one release directory. Answers the key id that vouched for it, or the refusal.
///
/// `extra` are trusted-keys files beyond the embedded list and the node's own (a test, or an operator with
/// a copy on a USB stick).
pub fn verify_release(directory: &Path, extra: &[PathBuf]) -> Result<String, ReleaseError> {
    verify_release_at(&directory.join(SUMS_FILE), None, extra)
}

/// Verify the release a `SHA256SUMS` file belongs to: the signature is `SHA256SUMS.sig` beside it, unless
/// the caller names the signature file for it (the second positional argument, or `--sig`).
///
/// This is the shape an operator types - `wa release verify <SHA256SUMS> [SHA256SUMS.sig]` - and the shape
/// the shell verifiers call, so there is one set of rules whether the release is named by a directory, by
/// its sums file, or by both of its files.
pub fn verify_release_at(sums_path: &Path, signature: Option<&Path>, extra: &[PathBuf]) -> Result<String, ReleaseError> {
    let sums = read(sums_path)?;
    let digest = sha256(&sums);
    let directory = match sums_path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.to_path_buf(),
        _ => PathBuf::from("."),
    };
    let signature_path = match signature {
        Some(path) => path.to_path_buf(),
        None => directory.join(SIGNATURE_FILE),
    };
    if !signature_path.is_file() {
        return Err(ReleaseError::new(2, format!(
            "{} has no {SIGNATURE_FILE}: refusing to install from a release that is not signed",
            directory.display())));
    }
    let signature_text = String::from_utf8_lossy(&read(&signature_path)?).to_string();
    let signature = parse_signature(&signature_text, &signature_path.display().to_string())?;
    if signature.sha256 != digest {
        return Err(ReleaseError::new(3, format!(
            "{} is about {}, the sums here are {}",
            signature_path.display(), hex_encode(&signature.sha256), hex_encode(&digest))));
    }

    let mut trusted = trusted_keys(extra)?;
    let announcement = directory.join(ANNOUNCEMENT_FILE);
    if announcement.is_file() {
        let announcement_signature_path = directory.join(format!("{ANNOUNCEMENT_FILE}.sig"));
        if !announcement_signature_path.is_file() {
            return Err(ReleaseError::new(5, format!(
                "a rotation is announced in {} with no {} signing it",
                announcement.display(), announcement_signature_path.display())));
        }
        let announced_bytes = read(&announcement)?;
        let announced_digest = sha256(&announced_bytes);
        let announced_text = String::from_utf8_lossy(&read(&announcement_signature_path)?).to_string();
        let announced = parse_signature(&announced_text, &announcement_signature_path.display().to_string())?;
        if announced.sha256 != announced_digest {
            return Err(ReleaseError::new(5, format!(
                "{} is about {}, {} is {}",
                announcement_signature_path.display(), hex_encode(&announced.sha256),
                announcement.display(), hex_encode(&announced_digest))));
        }
        let voucher = trusted.iter().find(|key| key.id == announced.key).ok_or_else(|| ReleaseError::new(5, format!(
            "the rotation in {} is signed by {}, which is not trusted here",
            announcement.display(), announced.key)))?;
        if !ed25519_verify(&voucher.public, &announced_digest, &announced.signature) {
            return Err(ReleaseError::new(5, format!(
                "the rotation in {} does not verify against the trusted key {}",
                announcement.display(), announced.key)));
        }
        trusted = parse_trusted_keys(&String::from_utf8_lossy(&announced_bytes), &announcement.display().to_string())?;
    }

    let public = trusted.iter().find(|key| key.id == signature.key).map(|key| key.public.clone()).ok_or_else(|| {
        ReleaseError::new(4, format!(
            "{} is signed by {}, which this node does not trust ({})",
            signature_path.display(), signature.key, trusted_key_list(&trusted)))
    })?;
    if !ed25519_verify(&public, &digest, &signature.signature) {
        return Err(ReleaseError::new(4, format!(
            "{} does not verify against the trusted key {}",
            signature_path.display(), signature.key)));
    }
    Ok(signature.key)
}

/// `wa release verify <dir|SHA256SUMS> [SHA256SUMS.sig] [--key <file>]... [--quiet]`
/// `wa release verify --sums <dir|SHA256SUMS> [--sig <file>] [--key <file>]... [--quiet]`
///
/// A scripts'-facing verb, so the deploy paths have one verifier binary-side as well as shell-side, and so
/// an operator can check a hand-copied release without installing it. Both spellings name the same two
/// files: the sums, and the signature that must be about them.
pub fn run(args: &[String]) -> i32 {
    if args.iter().any(|arg| arg == "--help" || arg == "-h") || args.is_empty() {
        println!("usage: wa release verify <dir|SHA256SUMS> [SHA256SUMS.sig] [--key <file>]... [--quiet]");
        println!("       wa release verify --sums <dir|SHA256SUMS> [--sig <file>] [--key <file>]... [--quiet]");
        return if args.is_empty() { 2 } else { 0 };
    }
    match args.first().map(String::as_str) {
        Some("verify") => {}
        Some(other) => {
            eprintln!("release_unknown_verb: '{other}' (the verb is 'verify')");
            return 2;
        }
        None => return 2,
    }
    let mut sums: Option<PathBuf> = None;
    let mut signature: Option<PathBuf> = None;
    let mut extra: Vec<PathBuf> = Vec::new();
    let mut quiet = false;
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--sums" => {
                let value = args.get(index + 1).cloned();
                index += 2;
                match value {
                    Some(value) => sums = Some(PathBuf::from(value)),
                    None => {
                        eprintln!("release_missing_value: --sums needs a path");
                        return 2;
                    }
                }
            }
            "--sig" => {
                let value = args.get(index + 1).cloned();
                index += 2;
                match value {
                    Some(value) => signature = Some(PathBuf::from(value)),
                    None => {
                        eprintln!("release_missing_value: --sig needs a path");
                        return 2;
                    }
                }
            }
            "--key" => {
                let value = args.get(index + 1).cloned();
                index += 2;
                match value {
                    Some(value) => extra.push(PathBuf::from(value)),
                    None => {
                        eprintln!("release_missing_value: --key needs a path");
                        return 2;
                    }
                }
            }
            "--quiet" => {
                quiet = true;
                index += 1;
            }
            other if !other.starts_with('-') => {
                // The two files by position: `wa release verify <SHA256SUMS> [SHA256SUMS.sig]`.
                if sums.is_none() {
                    sums = Some(PathBuf::from(other));
                } else if signature.is_none() {
                    signature = Some(PathBuf::from(other));
                } else {
                    // A third path is never guessed at: two files name a release, and a reader that
                    // picked one of three would be trusting its own choice.
                    eprintln!("release_unexpected_argument: '{other}' (the arguments are the sums, then the signature that must be about them)");
                    return 2;
                }
                index += 1;
            }
            other => {
                eprintln!("release_unknown_option: '{other}'");
                return 2;
            }
        }
    }
    let Some(sums) = sums else {
        eprintln!("release_missing_value: no SHA256SUMS was named (usage: wa release verify <dir|SHA256SUMS> [SHA256SUMS.sig])");
        return 2;
    };
    let release_dir = if sums.is_dir() { sums.clone() } else { sums.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from(".")) };
    let sums_file = if sums.is_dir() { sums.join(SUMS_FILE) } else { sums };
    match verify_release_at(&sums_file, signature.as_deref(), &extra) {
        Ok(key) => {
            if !quiet {
                println!("release signature verified: {key} ({})", release_dir.display());
            }
            0
        }
        Err(error) => {
            eprintln!("release_unsigned_or_forged: {}", error.message);
            error.code
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::rand::SystemRandom;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    struct Signer {
        id: String,
        pair: Ed25519KeyPair,
    }

    impl Signer {
        fn new(label: &str) -> Signer {
            let document = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).expect("ring keygen");
            let pair = Ed25519KeyPair::from_pkcs8(document.as_ref()).expect("ring pkcs8");
            Signer { id: format!("release-signing-{}", &hex_encode(&sha256(&sha256(pair.public_key().as_ref())))[..16]), pair }
        }

        fn public_hex(&self) -> String {
            hex_encode(self.pair.public_key().as_ref())
        }

        fn signature_file(&self, digest: &[u8]) -> String {
            format!("{SIGNATURE_HEADER}\nkey {}\nalg ed25519\nsha256 {}\nsig {}\n",
                    self.id, hex_encode(digest), hex_encode(self.pair.sign(digest).as_ref()))
        }
    }

    fn scratch(name: &str) -> PathBuf {
        // One directory per case, under the test process's own scratch: no network, no shared state.
        let base = std::env::temp_dir().join(format!("wa-release-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).expect("scratch directory");
        base
    }

    fn write(path: &Path, bytes: &[u8]) {
        std::fs::write(path, bytes).expect("write fixture");
    }

    fn trust_file(keys: &[&Signer]) -> String {
        let mut text = format!("{TRUST_HEADER}\n");
        for key in keys {
            text.push_str(&format!("key {} {}\n", key.id, key.public_hex()));
        }
        text
    }

    fn keys_file(directory: &Path, keys: &[&Signer]) -> PathBuf {
        let path = directory.join("trusted-keys.txt");
        write(&path, trust_file(keys).as_bytes());
        path
    }

    const SUMS: &[u8] = b"aaaa  wa-aarch64-unknown-linux-gnu-0123456789ab\nbbbb  wa-x86_64-unknown-linux-gnu-0123456789ab\n";

    /// A release directory signed by `signer`, with the sums unchanged.
    fn release(directory: &Path, signer: &Signer) {
        write(&directory.join(SUMS_FILE), SUMS);
        write(&directory.join(SIGNATURE_FILE), signer.signature_file(&sha256(SUMS)).as_bytes());
    }

    #[test]
    fn a_good_signature_verifies() {
        let directory = scratch("good");
        let key = Signer::new("a");
        release(&directory, &key);
        let trusted = keys_file(&directory, &[&key]);
        assert_eq!(verify_release(&directory, &[trusted]).expect("verified"), key.id);
    }

    #[test]
    fn a_flipped_byte_is_refused() {
        let directory = scratch("flipped");
        let key = Signer::new("a");
        release(&directory, &key);
        let trusted = keys_file(&directory, &[&key]);
        let mut flipped = SUMS.to_vec();
        flipped[2] ^= 0x01;
        write(&directory.join(SUMS_FILE), &flipped);
        let error = verify_release(&directory, &[trusted]).expect_err("a changed sums file must not verify");
        assert_eq!(error.code, 3);
        assert!(error.message.contains("SHA256SUMS.sig"), "{}", error.message);
    }

    #[test]
    fn an_unknown_key_is_refused() {
        let directory = scratch("unknown");
        let trusted_key = Signer::new("a");
        let stranger = Signer::new("b");
        release(&directory, &stranger);
        let trusted = keys_file(&directory, &[&trusted_key]);
        let error = verify_release(&directory, &[trusted]).expect_err("a signature by an unknown key must not verify");
        assert_eq!(error.code, 4);
        assert!(error.message.contains(&stranger.id), "{}", error.message);
    }

    #[test]
    fn a_missing_signature_is_refused() {
        let directory = scratch("missing");
        let key = Signer::new("a");
        write(&directory.join(SUMS_FILE), SUMS);
        let trusted = keys_file(&directory, &[&key]);
        let error = verify_release(&directory, &[trusted]).expect_err("an unsigned release must not verify");
        assert_eq!(error.code, 2);
        assert!(error.message.contains("SHA256SUMS.sig"), "{}", error.message);
    }

    #[test]
    fn a_key_this_node_does_not_trust_is_refused_by_name() {
        // This asserts the SENTENCE, not a premise about `config/release-keys.txt`: the embedded list is
        // empty only until the operator registers a release key (it gained one on 13/11), and this test
        // was written against the empty case - so it went red on the landing that registered the key, for
        // a reason that was about the file and not about the refusal.
        let directory = scratch("notrust");
        let key = Signer::new("a");
        release(&directory, &key);
        let error = verify_release(&directory, &[]).expect_err("a stranger's key is not trusted here");
        assert_eq!(error.code, 4);
        assert!(error.message.contains(&key.id), "{}", error.message);
        assert!(error.message.contains("does not trust"), "{}", error.message);
        let embedded = parse_trusted_keys(EMBEDDED_TRUSTED_KEYS, "embedded").expect("the embedded list parses");
        assert!(error.message.contains(&trusted_key_list(&embedded)), "{}", error.message);
    }

    #[test]
    fn the_trust_list_says_plainly_when_it_is_nobody() {
        // The branch the test above stopped reaching: an operator reading "does not trust (...)" must
        // never be left with an empty pair of brackets.
        assert_eq!(trusted_key_list(&[]), "no trusted key is configured");
        let keys = parse_trusted_keys(
            "wa-trusted-keys v1\nkey release-signing-aaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nkey release-signing-bbbb bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n",
            "a test list")
            .expect("two keys");
        assert_eq!(trusted_key_list(&keys), "release-signing-aaaa, release-signing-bbbb");
    }

    #[test]
    fn a_rotation_announced_by_a_trusted_key_is_accepted() {
        let directory = scratch("rotation");
        let old = Signer::new("a");
        let new = Signer::new("b");
        // The release is signed by the NEW key; the announcement is signed by the OLD, trusted one.
        release(&directory, &new);
        let announcement = trust_file(&[&old, &new]);
        write(&directory.join(ANNOUNCEMENT_FILE), announcement.as_bytes());
        write(&directory.join(format!("{ANNOUNCEMENT_FILE}.sig")),
              old.signature_file(&sha256(announcement.as_bytes())).as_bytes());
        let trusted = keys_file(&directory, &[&old]);
        assert_eq!(verify_release(&directory, &[trusted]).expect("a chained rotation verifies"), new.id);
    }

    #[test]
    fn a_rotation_signed_by_an_unknown_key_is_refused() {
        let directory = scratch("rotation-unknown");
        let old = Signer::new("a");
        let new = Signer::new("b");
        let stranger = Signer::new("x");
        release(&directory, &new);
        let announcement = trust_file(&[&old, &new]);
        write(&directory.join(ANNOUNCEMENT_FILE), announcement.as_bytes());
        write(&directory.join(format!("{ANNOUNCEMENT_FILE}.sig")),
              stranger.signature_file(&sha256(announcement.as_bytes())).as_bytes());
        let trusted = keys_file(&directory, &[&old]);
        let error = verify_release(&directory, &[trusted]).expect_err("an unknown key cannot announce a rotation");
        assert_eq!(error.code, 5);
        assert!(error.message.contains(&stranger.id), "{}", error.message);
    }

    #[test]
    fn a_second_rotation_chains_through_the_announced_key() {
        // A -> B accepted, then a release named AB announces B -> C signed by B: the trust that mattered
        // is the one the PREVIOUS release established, which is what a rotation chain means.
        let first = scratch("chain-first");
        let a = Signer::new("a");
        let b = Signer::new("b");
        let c = Signer::new("c");
        release(&first, &b);
        let announced = trust_file(&[&a, &b]);
        write(&first.join(ANNOUNCEMENT_FILE), announced.as_bytes());
        write(&first.join(format!("{ANNOUNCEMENT_FILE}.sig")), a.signature_file(&sha256(announced.as_bytes())).as_bytes());
        let trusted = keys_file(&first, &[&a]);
        assert_eq!(verify_release(&first, &[trusted]).expect("A vouches for B"), b.id);

        // The next release is signed by C and its announcement is signed by B, which the operator added to
        // the node's own list after the first rotation.
        let second = scratch("chain-second");
        release(&second, &c);
        let next = trust_file(&[&a, &b, &c]);
        write(&second.join(ANNOUNCEMENT_FILE), next.as_bytes());
        write(&second.join(format!("{ANNOUNCEMENT_FILE}.sig")), b.signature_file(&sha256(next.as_bytes())).as_bytes());
        let carried = keys_file(&second, &[&a, &b]);
        assert_eq!(verify_release(&second, &[carried]).expect("B vouches for C"), c.id);
    }

    #[test]
    fn the_committed_fixtures_agree_with_the_vaults_signer() {
        // tests/fixtures/release-sign/ was produced by the Python signer the vault runs
        // (tests/fixtures/release-sign/generate.py). This is the cross-implementation check: ring, in the
        // binary, must agree with those files case by case - including the two refusals a hostile release
        // would have to pass.
        let base = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/release-sign");
        let keys = base.join("keys.txt");
        let cases = [("good", 0), ("flipped", 3), ("unknown", 4), ("missing", 2), ("rotation", 0), ("rotation-unknown", 5)];
        for (case, expected) in cases {
            let directory = base.join(case);
            let result = verify_release(&directory, std::slice::from_ref(&keys));
            match (result, expected) {
                (Ok(_), 0) => {}
                (Err(error), code) if code != 0 => assert_eq!(error.code, code, "{case}: {}", error.message),
                (other, code) => panic!("fixture {case} verified as {other:?}, expected code {code}"),
            }
        }
    }

    #[test]
    fn the_two_files_by_position_name_the_same_release_as_the_directory() {
        // `wa release verify <SHA256SUMS> [SHA256SUMS.sig]`: what an operator types, and what the
        // shell verifiers could hand a node instead of a directory.
        let directory = scratch("positional");
        let key = Signer::new("a");
        release(&directory, &key);
        let trusted = keys_file(&directory, &[&key]);
        let sums = directory.join(SUMS_FILE);
        let signature = directory.join(SIGNATURE_FILE);
        assert_eq!(verify_release_at(&sums, None, &[trusted.clone()]).expect("sums alone"), key.id);
        assert_eq!(verify_release_at(&sums, Some(&signature), &[trusted]).expect("sums and sig"), key.id);
    }

    #[test]
    fn a_named_signature_that_is_not_about_these_sums_is_refused() {
        // The point of naming the signature is not to make verification optional: it must still be about
        // exactly the bytes handed in.
        let directory = scratch("named-sig");
        let key = Signer::new("a");
        release(&directory, &key);
        let trusted = keys_file(&directory, &[&key]);
        let other = scratch("named-sig-other");
        write(&other.join(SIGNATURE_FILE), key.signature_file(&sha256(b"another release\n")).as_bytes());
        let error = verify_release_at(&directory.join(SUMS_FILE), Some(&other.join(SIGNATURE_FILE)), &[trusted])
            .expect_err("a signature about other bytes must not verify");
        assert_eq!(error.code, 3);
    }

    #[test]
    fn a_bad_signature_is_refused_by_the_named_path_too() {
        let directory = scratch("named-sig-flipped");
        let key = Signer::new("a");
        release(&directory, &key);
        let trusted = keys_file(&directory, &[&key]);
        let signature = directory.join(SIGNATURE_FILE);
        let text = std::fs::read_to_string(&signature).expect("read sig");
        let flipped = text.replace("sig ", "sig 0");
        write(&signature, flipped.as_bytes());
        let error = verify_release_at(&directory.join(SUMS_FILE), Some(&signature), &[trusted])
            .expect_err("a malformed signature is refused, not skipped");
        assert_eq!(error.code, 6);
    }

    #[test]
    fn the_embedded_list_parses_and_names_itself_when_empty() {
        // Whatever the operator has put in config/release-keys.txt, the binary must be able to read it: an
        // embedded list that does not parse is a node that can never install a release.
        let keys = parse_trusted_keys(EMBEDDED_TRUSTED_KEYS, "embedded").expect("the embedded key list parses");
        for key in &keys {
            assert_eq!(key.public.len(), 32);
            assert!(key.id.starts_with("release-signing-"), "{}", key.id);
        }
    }
}
