//! The operator's side of the roster: `wa fleet keygen`, `wa fleet sign`, `wa fleet show`.
//!
//! Rolling the mesh out to a real node needs two things an operator had no way to make: a fleet key
//! and a roster signed with it. `docs/MESH.md` §1 describes the document and the exact bytes that are
//! signed; this module is the only code that *produces* one. Nothing here runs inside a node's call
//! path — a node reads and verifies rosters, it never signs one, which is why a compromised node
//! cannot promote itself ([`crate::hierarchy`] takes the level from the signed file).
//!
//! Three rules, each a refusal an operator will meet rather than a silent success:
//!
//! * **The private key goes to exactly one explicit path.** `keygen` writes it there and nowhere else,
//!   `create_new` so it can never overwrite a key, mode `0600` on unix, and it refuses a path inside
//!   the node home (a node's own directory is what a backup, a bundle or a component grant already
//!   reaches) or inside a git checkout (a fleet key must not be one `git add -A` away from a remote).
//! * **A roster is signed only if it is a roster.** The document is parsed with the same strict reader
//!   the nodes use: unknown fields, a duplicate `node_id`, a `node_id` that is not `sha256(public_key)`
//!   and a bad address are all refused *before* the key is used, so the operator never ships a
//!   document that every node would refuse.
//! * **The signed file is a new file.** The template the operator wrote is left as it was and the
//!   signature lands in `<name>.signed.json` (override `--out`), so re-signing after an edit and
//!   reading back what was signed never destroy the draft.
use crate::identity::{self, Identity};
use crate::policy::MeshPolicy;
use crate::roster::{Roster, RosterSigner};
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Component, Path, PathBuf};

/// The mode the private key is created with on unix. A fleet key is the trust anchor of the whole
/// roster, so it is not group- or world-readable even for the moment between create and chmod.
pub const KEY_FILE_MODE: u32 = 0o600;
/// Where a signed roster lands when the operator does not say: beside the template, never over it.
pub const SIGNED_SUFFIX: &str = "signed";
/// `--expires-days` is bounded: a roster that outlives the machine it was made on is a key nobody is
/// watching, and "never" is written as `0` rather than as a very large number.
pub const MAX_EXPIRY_DAYS: u64 = 3650;

/// The node's own directory (`<home>/.wasm-agent`): the one place `keygen` refuses, because that is
/// what this node's own backups, bundles and file grants already reach.
pub fn node_home() -> PathBuf {
    PathBuf::from(wa_host_support::paths::resolve_home()).join(".wasm-agent")
}

fn absolute(path: &Path) -> PathBuf {
    if path.is_absolute() {
        return path.to_path_buf();
    }
    std::env::current_dir().unwrap_or_default().join(path)
}

/// A lexical normalisation: no filesystem access, so it works for a path that does not exist yet (the
/// key file, by definition). Symlinks are not resolved — a refusal does not have to be perfect to be
/// useful, and resolving them would need the file to exist.
fn lexical(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn text_of(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/").to_ascii_lowercase()
}

fn inside(path: &Path, root: &Path) -> bool {
    let (path, root) = (text_of(path), text_of(root));
    path == root || path.starts_with(&(root.trim_end_matches('/').to_string() + "/"))
}

/// Is `path` (or anything above it) inside a git checkout? The check is `<dir>/.git` existing, which
/// covers both a normal clone (a directory) and a linked worktree (a file).
fn in_git_checkout(path: &Path) -> bool {
    let mut current = Some(lexical(&absolute(path)));
    while let Some(directory) = current {
        if directory.join(".git").exists() {
            return true;
        }
        current = directory.parent().map(Path::to_path_buf);
    }
    false
}

/// The refusals every produced key shares. Each answer is one code, so a script can branch on it.
pub fn check_key_path(out: &Path) -> Result<PathBuf, String> {
    if out.as_os_str().is_empty() || out.to_string_lossy().trim().is_empty() {
        return Err("key_path_required".into());
    }
    let out = lexical(&absolute(out));
    if out.is_dir() {
        return Err("key_path_is_a_directory".into());
    }
    if out.exists() {
        return Err("key_path_exists".into());
    }
    let home = node_home();
    if inside(&out, &home) {
        return Err(format!(
            "key_path_in_node_home: the fleet key must not live in {}",
            home.display()
        ));
    }
    if in_git_checkout(&out) {
        return Err(
            "key_path_in_git_checkout: the fleet key must not be somewhere `git add` reaches".into(),
        );
    }
    Ok(out)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Keygen {
    pub path: PathBuf,
    pub public_key: String,
    pub node_id: String,
    pub mode: &'static str,
}

/// Create a fleet key at exactly `out`, and nowhere else.
pub fn keygen(out: &Path) -> Result<Keygen, String> {
    let out = check_key_path(out)?;
    let (pkcs8_hex, identity) = identity::generate()?;
    if let Some(parent) = out.parent() {
        wa_host_support::paths::private_dir(parent);
    }
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(KEY_FILE_MODE);
    }
    let mut file = options.open(&out).map_err(|error| match error.kind() {
        std::io::ErrorKind::AlreadyExists => "key_path_exists".to_string(),
        _ => format!("{}: {error}", out.display()),
    })?;
    file.write_all(pkcs8_hex.as_bytes())
        .and_then(|()| file.write_all(b"\n"))
        .map_err(|error| format!("{}: {error}", out.display()))?;
    drop(file);
    Ok(Keygen {
        path: out,
        public_key: identity.public_key,
        node_id: identity.node_id,
        mode: if cfg!(unix) {
            "0600"
        } else {
            // Windows has no POSIX mode; std cannot set an ACL either. Said out loud rather than
            // claimed: the file is created under the operator's own profile and nothing claims 0600.
            "unix-0600 (this host has no POSIX mode; the file is owner-created under the operator's profile)"
        },
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signed {
    pub path: PathBuf,
    pub public_key: String,
    pub fleet: String,
    pub fingerprint: String,
    pub issued_at: u64,
    pub expires_at: u64,
    pub nodes: usize,
    pub signature: String,
    pub replaced_signature: bool,
    /// The roster's monotonic revision (`docs/MESH.md` §1). `0` is a legacy document.
    pub revision: u32,
    /// The chain hash this document names as its predecessor.
    pub prev_hash: String,
}

/// The path a signed roster is written to: `<stem>.signed.json` beside the template.
pub fn signed_path(template: &Path) -> PathBuf {
    let stem = template
        .file_stem()
        .map(|stem| stem.to_string_lossy().to_string())
        .unwrap_or_else(|| "roster".into());
    template.with_file_name(format!("{stem}.{SIGNED_SUFFIX}.json"))
}

/// Sign `roster_path` with the key at `key_path`, writing the signed document to `out` (or beside the
/// template) and leaving the template untouched.
pub fn sign(
    roster_path: &Path,
    key_path: &Path,
    out: Option<&Path>,
    expires_days: Option<u64>,
    now_s: u64,
) -> Result<Signed, String> {
    let mut key = Identity::open(key_path)
        .map_err(|error| format!("fleet_key_unusable: {}: {error}", key_path.display()))?;
    sign_with_signer(roster_path, &mut key, out, expires_days, now_s, None)
}

/// Sign with any signer: the operator's node key, or the fleet key the vault holds
/// (`wa fleet sign <roster.json> --key vault:<name>`, docs/MESH.md §1, docs/VAULT.md).
///
/// `revision` overrides the document's revision. With no override, re-signing a document that already
/// carries a signature advances it by one and chains it (`prev_hash` = the predecessor's chain hash), so
/// a change to a live fleet is a *new revision* rather than a same-numbered fork; a fresh template, and
/// a legacy (`revision: 0`) roster, keep their own revision exactly as before.
pub fn sign_with_signer(
    roster_path: &Path,
    signer: &mut dyn RosterSigner,
    out: Option<&Path>,
    expires_days: Option<u64>,
    now_s: u64,
    revision: Option<u32>,
) -> Result<Signed, String> {
    if let Some(days) = expires_days {
        if days == 0 || days > MAX_EXPIRY_DAYS {
            return Err(format!("expires_days_out_of_range:1..={MAX_EXPIRY_DAYS}"));
        }
    }
    let text = std::fs::read_to_string(roster_path)
        .map_err(|error| format!("roster_unreadable: {}: {error}", roster_path.display()))?;
    // Strict on purpose (docs/MESH.md §1): unknown fields, a duplicate node id and a node id that is
    // not the hash of its key are load errors, and signing is not the place to relax that.
    let mut roster = Roster::parse(&text).map_err(|error| format!("roster_invalid: {}", error.0))?;
    let replaced_signature = !roster.signature.trim().is_empty();
    // The predecessor's chain hash has to be taken BEFORE `revision`/`issued_at` change: it is the hash
    // of the document as it stands, its signature included.
    let predecessor = if replaced_signature { roster.chain_hash() } else { roster.prev_hash.clone() };
    roster.issued_at = now_s;
    if let Some(days) = expires_days {
        roster.expires_at = now_s.saturating_add(days.saturating_mul(86_400));
    }
    match revision {
        Some(value) => roster.revision = value,
        None if replaced_signature && roster.revision >= 1 => {
            roster.revision = roster.revision.saturating_add(1);
            roster.prev_hash = predecessor;
        }
        None => {}
    }
    roster.sign_with(signer).map_err(|error| format!("roster_invalid: {}", error.0))?;
    let target = out.map(lexical).unwrap_or_else(|| signed_path(roster_path));
    let mut document = serde_json::to_string_pretty(&roster).map_err(|error| error.to_string())?;
    document.push('\n');
    write_atomic(&target, document.as_bytes())?;
    let fingerprint = roster.fingerprint();
    Ok(Signed {
        path: target,
        public_key: signer.public_key(),
        fleet: roster.fleet.clone(),
        fingerprint,
        issued_at: roster.issued_at,
        expires_at: roster.expires_at,
        nodes: roster.nodes.len(),
        signature: roster.signature,
        replaced_signature,
        revision: roster.revision,
        prev_hash: roster.prev_hash,
    })
}

pub(crate) fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            wa_host_support::paths::private_dir(parent);
        }
    }
    let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
    std::fs::write(&temporary, bytes).map_err(|error| format!("{}: {error}", temporary.display()))?;
    if std::fs::rename(&temporary, path).is_err() {
        // Windows refuses to rename over an existing file.
        let _ = std::fs::remove_file(path);
        std::fs::rename(&temporary, path).map_err(|error| format!("{}: {error}", path.display()))?;
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShownNode {
    pub name: String,
    pub level: u8,
    pub node_id: String,
    pub public_key: String,
    pub addresses: Vec<String>,
    pub revoked_at: u64,
    pub revoked: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Showed {
    pub fleet: String,
    pub fingerprint: String,
    pub issued_at: u64,
    pub expires_at: u64,
    pub signature: String,
    pub verified: bool,
    pub reason: String,
    pub key_source: String,
    pub key: String,
    pub entries: Vec<ShownNode>,
}

/// The public key a `--key` argument names: 64 hex characters, or a file holding either the public
/// key or the operator's private key (whose public half is derived, never printed).
pub fn key_argument(argument: &str) -> Result<(String, String), String> {
    let argument = argument.trim();
    if identity::unhex(argument).is_some() && argument.len() == 64 {
        return Ok((argument.to_ascii_lowercase(), "argument".into()));
    }
    let path = Path::new(argument);
    if !path.exists() {
        return Err(format!("key_argument_unreadable: {argument} is neither 64 hex characters nor a readable file"));
    }
    if let Ok(identity) = Identity::open(path) {
        return Ok((identity.public_key, format!("{} (public half)", path.display())));
    }
    let text = std::fs::read_to_string(path)
        .map_err(|error| format!("key_argument_unreadable: {}: {error}", path.display()))?;
    let text = text.trim();
    if text.len() == 64 && identity::unhex(text).is_some() {
        return Ok((text.to_ascii_lowercase(), path.display().to_string()));
    }
    Err(format!("key_argument_unreadable: {} holds neither a public key nor a node key", path.display()))
}

/// Verify a roster and describe its levels. `default_key` is `mesh.roster_key` from this node's own
/// `policy.json`; an explicit `key` argument wins over it.
pub fn show(roster_path: &Path, key: Option<&str>, default_key: &str, now_s: u64) -> Result<Showed, String> {
    let text = std::fs::read_to_string(roster_path)
        .map_err(|error| format!("roster_unreadable: {}: {error}", roster_path.display()))?;
    let roster = Roster::parse(&text).map_err(|error| format!("roster_invalid: {}", error.0))?;
    let (key, key_source) = match key {
        Some(argument) => key_argument(argument)?,
        None => (default_key.trim().to_ascii_lowercase(), "policy.json mesh.roster_key".to_string()),
    };
    let (verified, reason) = if key.is_empty() {
        (false, "roster_key_missing: no --key and this node's policy pins no fleet key".to_string())
    } else {
        match crate::seam::verify_roster(&roster, &key, now_s) {
            Ok(()) => (true, "verified".to_string()),
            Err(error) => (false, error.0),
        }
    };
    let fingerprint = roster.fingerprint();
    Ok(Showed {
        fleet: roster.fleet.clone(),
        fingerprint,
        issued_at: roster.issued_at,
        expires_at: roster.expires_at,
        signature: roster.signature,
        verified,
        reason,
        key_source,
        key,
        entries: roster
            .nodes
            .iter()
            .map(|node| ShownNode {
                name: node.name.clone(),
                level: node.level,
                node_id: node.node_id.clone(),
                public_key: node.public_key.clone(),
                addresses: node.addresses.clone(),
                revoked_at: node.revoked_at,
                revoked: node.is_revoked(now_s),
            })
            .collect(),
    })
}

fn show_json(shown: &Showed, path: &Path) -> Value {
    json!({
        "ok": shown.verified,
        "error": if shown.verified { Value::Null } else { json!(shown.reason) },
        "path": path.to_string_lossy(),
        "fleet": shown.fleet,
        "fingerprint": shown.fingerprint,
        "issued_at": shown.issued_at,
        "expires_at": shown.expires_at,
        "signature": shown.signature,
        "verified": shown.verified,
        "reason": shown.reason,
        "key": shown.key,
        "key_source": shown.key_source,
        "nodes": shown.entries.iter().map(|entry| json!({
            "name": entry.name,
            "level": entry.level,
            "node_id": entry.node_id,
            "public_key": entry.public_key,
            "addresses": entry.addresses,
            "revoked_at": entry.revoked_at,
            "revoked": entry.revoked,
        })).collect::<Vec<_>>(),
    })
}

fn usage() {
    println!("wa fleet keygen --out <path>");
    println!("    create a fleet ed25519 key (the roster's trust anchor) at exactly <path>: mode 0600,");
    println!("    never inside the node home or a git checkout, never over an existing key. Prints the");
    println!("    public key to pin as mesh.roster_key (docs/MESH.md §1).");
    println!("wa fleet sign <roster.json> --key <path> [--expires-days N] [--out <path>]");
    println!("    sign the roster's canonical bytes and write the signed document (default:");
    println!("    <name>.signed.json). Refuses unknown fields, duplicate ids, a bad address and a");
    println!("    non-roster template BEFORE it uses the key.");
    println!("wa fleet show <roster.json> [--key <hex|path>]");
    println!("    verify a roster and print its levels; with no --key it uses this node's");
    println!("    policy.json mesh.roster_key. Exits 1 when the roster does not verify.");
    println!("wa fleet push-roster <node> [--replace-key <hex>] [--port N] [--bind ADDR]");
    println!("    install this fleet's roster on a node that already accepts this one (lua/core/fleet.lua).");
    println!("wa fleet revoke <node|node_id> --roster <signed.json> --key <path|vault:name> [--at <unix>] [--out <path>]");
    println!("    set the node's revoked_at, advance the roster revision, chain it (prev_hash) and re-sign.");
    println!("wa fleet rotate --roster <signed.json> --key <new: path|vault:name> [--out <path>]");
    println!("    re-sign the fleet under a NEW key as the next revision, and print the anchor command.");
    println!("wa fleet anchor <signed.json> --key <old: path|vault:name> --new <new public key>");
    println!("    sign mesh-anchor-v1|<new key>|<fingerprint> with the key a node pins now (--replace-key).");
    println!("  --key vault:<name> uses the fleet key held in the vault (--vault-dir, else $WASM_AGENT_VAULT_DIR).");
}

/// `--key vault:<name>` -> the vault-backed signer. `Err(None)` (the inner `Option`) means "not a vault
/// key": the caller falls through to the key-file path unchanged, so `wa fleet sign --key <path>` keeps
/// its exact behaviour.
type VaultSignerLookup = Result<Box<dyn RosterSigner>, Option<String>>;

fn vault_signer(key: &str, vault_dir: Option<&str>, policy: Option<&str>) -> VaultSignerLookup {
    if !key.starts_with(crate::fleetchange::VAULT_PREFIX) {
        return Err(None);
    }
    match crate::fleetchange::signer_for(key, vault_dir.map(Path::new), policy.map(Path::new)) {
        Ok(signer) => Ok(signer),
        Err(error) => Err(Some(error)),
    }
}

/// The signer for `revoke`/`rotate`/`anchor`: a vault key or a key file, always the same two doors.
fn change_signer(key: &str, args: &[String]) -> Result<Box<dyn RosterSigner>, String> {
    crate::fleetchange::signer_for(
        key,
        flag_value(args, "--vault-dir").as_deref().map(Path::new),
        flag_value(args, "--policy").as_deref().map(Path::new),
    )
}

fn flag_value(args: &[String], name: &str) -> Option<String> {
    let mut iter = args.iter();
    while let Some(argument) = iter.next() {
        if argument == name {
            return iter.next().cloned();
        }
    }
    None
}

/// `wa fleet <sub> …` for the three operator commands. `None` means this is not one of them (the
/// caller falls through to the Lua CLI, which owns `push-roster`).
pub fn run(args: &[String]) -> Option<i32> {
    let sub = args.get(1).map(String::as_str).unwrap_or("");
    if !matches!(sub, "keygen" | "sign" | "show" | "revoke" | "rotate" | "anchor") {
        return None;
    }
    if args.iter().skip(2).any(|argument| argument == "--help" || argument == "-h") {
        usage();
        return Some(0);
    }
    let now_s = crate::wire::now_seconds();
    match sub {
        "keygen" => {
            let Some(out) = flag_value(args, "--out") else {
                eprintln!("keygen needs --out <path>: the private key is written only to a path you name");
                return Some(2);
            };
            let answer = match keygen(Path::new(&out)) {
                Ok(created) => json!({
                    "ok": true,
                    "path": created.path.to_string_lossy(),
                    "public_key": created.public_key,
                    "node_id": created.node_id,
                    "mode": created.mode,
                    "pin": "put this public key in policy.json as mesh.roster_key, then sign the roster with `wa fleet sign`",
                }),
                Err(error) => json!({"ok": false, "error": error}),
            };
            println!("{answer}");
            Some(if answer["ok"] == true { 0 } else { 1 })
        }
        "sign" => {
            let Some(template) = args.get(2).filter(|argument| !argument.starts_with("--")) else {
                eprintln!("sign needs a roster file: wa fleet sign <roster.json> --key <path>");
                return Some(2);
            };
            let Some(key) = flag_value(args, "--key") else {
                eprintln!("sign needs --key <path>: the roster is signed by the operator's fleet key");
                return Some(2);
            };
            let expires = match flag_value(args, "--expires-days") {
                Some(text) => match text.parse::<u64>() {
                    Ok(days) if days > 0 && days <= MAX_EXPIRY_DAYS => Some(days),
                    _ => {
                        eprintln!("--expires-days takes 1..={MAX_EXPIRY_DAYS}");
                        return Some(2);
                    }
                },
                None => None,
            };
            let out = flag_value(args, "--out");
            let vault_dir = flag_value(args, "--vault-dir");
            let policy = flag_value(args, "--policy");
            let revision = match flag_value(args, "--revision") {
                Some(text) => match text.parse::<u32>() {
                    Ok(value) => Some(value),
                    Err(_) => {
                        eprintln!("--revision takes a number");
                        return Some(2);
                    }
                },
                None => None,
            };
            let answer = match vault_signer(&key, vault_dir.as_deref(), policy.as_deref()) {
                // `--key vault:<name>`: the fleet key lives in the vault (docs/VAULT.md). It is opened
                // for this one signature, and the signature is audited there.
                Ok(mut signer) => sign_with_signer(
                    Path::new(template),
                    signer.as_mut(),
                    out.as_deref().map(Path::new),
                    expires,
                    now_s,
                    revision,
                ),
                // Anything else is a key file, exactly as before: `vault_signer` answers `Err(None)`.
                Err(None) => sign(
                    Path::new(template),
                    Path::new(&key),
                    out.as_deref().map(Path::new),
                    expires,
                    now_s,
                ),
                Err(Some(error)) => Err(error),
            };
            let answer = match answer {
                Ok(signed) => json!({
                    "ok": true,
                    "path": signed.path.to_string_lossy(),
                    "fleet": signed.fleet,
                    "fingerprint": signed.fingerprint,
                    "issued_at": signed.issued_at,
                    "expires_at": signed.expires_at,
                    "nodes": signed.nodes,
                    "signature": signed.signature,
                    "replaced_signature": signed.replaced_signature,
                    "revision": signed.revision,
                    "prev_hash": signed.prev_hash,
                    "public_key": signed.public_key,
                    "template": template,
                }),
                Err(error) => json!({"ok": false, "error": error}),
            };
            println!("{answer}");
            Some(if answer["ok"] == true { 0 } else { 1 })
        }
        "revoke" => {
            let Some(selector) = args.get(2).filter(|argument| !argument.starts_with("--")) else {
                eprintln!("revoke needs a node: wa fleet revoke <node|node_id> --roster <signed.json> --key <path|vault:name>");
                return Some(2);
            };
            let (Some(roster), Some(key)) = (flag_value(args, "--roster"), flag_value(args, "--key")) else {
                eprintln!("revoke needs --roster <signed.json> and --key <path|vault:name>");
                return Some(2);
            };
            let answer = match change_signer(&key, args) {
                Ok(mut signer) => {
                    let out = flag_value(args, "--out");
                    let at = flag_value(args, "--at")
                        .and_then(|text| text.parse::<u64>().ok())
                        .unwrap_or(now_s);
                    match crate::fleetchange::revoke(
                        Path::new(&roster),
                        selector,
                        signer.as_mut(),
                        out.as_deref().map(Path::new),
                        at,
                    ) {
                        Ok(changed) => crate::fleetchange::json_changed(&changed),
                        Err(error) => json!({"ok": false, "error": error}),
                    }
                }
                Err(error) => json!({"ok": false, "error": error}),
            };
            println!("{answer}");
            Some(if answer["ok"] == true { 0 } else { 1 })
        }
        "rotate" => {
            let (Some(roster), Some(key)) = (flag_value(args, "--roster"), flag_value(args, "--key")) else {
                eprintln!("rotate needs --roster <signed.json> and --key <the NEW key: path|vault:name>");
                return Some(2);
            };
            let answer = match change_signer(&key, args) {
                Ok(mut signer) => {
                    let out = flag_value(args, "--out");
                    match crate::fleetchange::rotate(
                        Path::new(&roster),
                        signer.as_mut(),
                        out.as_deref().map(Path::new),
                        now_s,
                    ) {
                        Ok(rotated) => crate::fleetchange::json_rotated(&rotated),
                        Err(error) => json!({"ok": false, "error": error}),
                    }
                }
                Err(error) => json!({"ok": false, "error": error}),
            };
            println!("{answer}");
            Some(if answer["ok"] == true { 0 } else { 1 })
        }
        "anchor" => {
            let Some(roster) = args.get(2).filter(|argument| !argument.starts_with("--")) else {
                eprintln!("anchor needs the signed roster: wa fleet anchor <signed.json> --key <old key> --new <hex>");
                return Some(2);
            };
            let (Some(key), Some(new_key)) = (flag_value(args, "--key"), flag_value(args, "--new")) else {
                eprintln!("anchor needs --key <the key a node pins NOW> and --new <the new fleet public key>");
                return Some(2);
            };
            let answer = match change_signer(&key, args) {
                Ok(mut signer) => match crate::fleetchange::anchor(Path::new(roster), signer.as_mut(), &new_key) {
                    Ok(signature) => json!({
                        "ok": true,
                        "signature": signature,
                        "next": "wa fleet push-roster <node> --replace-key <signature>",
                    }),
                    Err(error) => json!({"ok": false, "error": error}),
                },
                Err(error) => json!({"ok": false, "error": error}),
            };
            println!("{answer}");
            Some(if answer["ok"] == true { 0 } else { 1 })
        }
        "show" => {
            let Some(roster) = args.get(2).filter(|argument| !argument.starts_with("--")) else {
                eprintln!("show needs a roster file: wa fleet show <roster.json> [--key <hex|path>]");
                return Some(2);
            };
            let default_key = MeshPolicy::from_policy_file(crate::host_call::Paths::resolve().policy)
                .map(|policy| policy.roster_key)
                .unwrap_or_default();
            let answer = match show(
                Path::new(roster),
                flag_value(args, "--key").as_deref(),
                &default_key,
                now_s,
            ) {
                Ok(shown) => show_json(&shown, Path::new(roster)),
                Err(error) => json!({"ok": false, "error": error}),
            };
            // A roster that does not verify is a failure and a non-zero exit: `show` is also the
            // operator's check before they install one.
            println!("{answer}");
            Some(if answer["ok"] == true { 0 } else { 1 })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::roster::{Draft, RosterNode};
    use crate::testkit;

    /// One key pair living at `<dir>/fleet.key`, which is also the path `sign`/`show` are given.
    fn key_at(dir: &Path) -> (Identity, PathBuf) {
        let path = dir.join("fleet.key");
        (Identity::load(&path).expect("key"), path)
    }

    fn template(path: &Path, fleet: &Identity, nodes: Vec<RosterNode>) {
        let roster = Draft {
            fleet: "ohana".into(),
            issued_at: 0,
            expires_at: 0,
            nodes,
        }
        .sign(fleet);
        // An unsigned template: the operator's draft, exactly what `sign` accepts.
        let mut value = serde_json::to_value(&roster).unwrap();
        value["signature"] = json!("");
        std::fs::write(path, serde_json::to_string_pretty(&value).unwrap()).unwrap();
    }

    #[test]
    fn keygen_writes_one_private_key_and_prints_its_public_half() {
        let dir = testkit::temp_dir("keygen");
        let out = dir.join("fleet.key");
        let created = keygen(&out).expect("keygen");
        assert!(out.exists());
        assert_eq!(created.node_id, identity::derive_node_id(&created.public_key).unwrap());
        let written = std::fs::read_to_string(&out).unwrap();
        let reloaded = Identity::from_pkcs8_hex(written.trim()).unwrap();
        assert_eq!(reloaded.public_key, created.public_key);
        // The file holds only that key, and nothing else is written beside it.
        assert!(written.trim().len() > 64 && identity::unhex(written.trim()).is_some());
        // The keygen dir also holds nothing else: `key_at` is not used here.
        assert_eq!(
            std::fs::read_dir(&dir).unwrap().count(),
            1,
            "keygen writes one file and nothing else"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&out).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, KEY_FILE_MODE, "the private key must be 0600");
        }
        // Never over an existing key: a second keygen at the same path is refused, not a new identity.
        assert_eq!(keygen(&out).unwrap_err(), "key_path_exists");
        assert_eq!(std::fs::read_to_string(&out).unwrap(), written);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn keygen_refuses_the_node_home_and_a_git_checkout() {
        let dir = testkit::temp_dir("keygen-refuse");
        let home = dir.join(".wasm-agent");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(dir.join("home/git/.git")).unwrap();
        // The refusal reads the *process's* node home, so the rule is asserted through the helper with
        // an explicit root: the same code, one path instead of two.
        assert!(inside(&lexical(&home.join("fleet.key")), &home));
        assert!(!inside(&lexical(&dir.join("elsewhere/fleet.key")), &home));
        assert!(in_git_checkout(&dir.join("home/git/sub/fleet.key")));
        assert!(!in_git_checkout(&dir.join("home/plain/fleet.key")));
        std::fs::create_dir_all(dir.join("home/worktree")).unwrap();
        std::fs::write(dir.join("home/worktree/.git"), "gitdir: elsewhere").unwrap();
        assert!(
            in_git_checkout(&dir.join("home/worktree/deeper/fleet.key")),
            "a linked worktree has a .git file"
        );
        assert_eq!(check_key_path(Path::new("")).unwrap_err(), "key_path_required");
        assert_eq!(check_key_path(&dir).unwrap_err(), "key_path_is_a_directory");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn sign_verifies_with_the_key_and_leaves_the_template_alone() {
        let dir = testkit::temp_dir("sign");
        let (fleet, key_path) = key_at(&dir);
        let member = testkit::Member::new("laptop", 0, &["127.0.0.1:8891"]);
        let template_path = dir.join("roster.json");
        template(&template_path, &fleet, vec![member.node.clone()]);
        let before = std::fs::read_to_string(&template_path).unwrap();

        let signed = sign(&template_path, &key_path, None, Some(30), 1_762_000_000).unwrap();
        assert_eq!(signed.path, dir.join("roster.signed.json"));
        assert_eq!(signed.nodes, 1);
        assert_eq!(signed.expires_at, 1_762_000_000 + 30 * 86_400);
        assert_eq!(
            std::fs::read_to_string(&template_path).unwrap(),
            before,
            "the template is not rewritten"
        );

        let shown = show(&signed.path, Some(&fleet.public_key), "", 1_762_000_100).unwrap();
        assert!(shown.verified, "{}", shown.reason);
        assert_eq!(shown.entries[0].level, 0);
        assert_eq!(shown.entries[0].name, "laptop");
        // The signature is a real one over the documented canonical bytes.
        crate::seam::verify_roster(&Roster::from_file(&signed.path).unwrap(), &fleet.public_key, 1_762_000_100).unwrap();

        // A tampered document is refused, with the reason a node would give.
        let mut tampered = Roster::from_file(&signed.path).unwrap();
        tampered.nodes[0].level = 9;
        std::fs::write(&signed.path, serde_json::to_string(&tampered).unwrap()).unwrap();
        let refused = show(&signed.path, Some(&fleet.public_key), "", 1_762_000_100).unwrap();
        assert!(!refused.verified);
        assert_eq!(refused.reason, "roster_unverified:bad_signature");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn sign_refuses_a_template_a_node_would_refuse() {
        let dir = testkit::temp_dir("sign-refuse");
        let (fleet, key_path) = key_at(&dir);
        let member = testkit::Member::new("laptop", 0, &[]);
        let template_path = dir.join("roster.json");

        // An unknown field: a misspelt `level` must not sign as level 0.
        template(&template_path, &fleet, vec![member.node.clone()]);
        let text = std::fs::read_to_string(&template_path).unwrap().replace("\"level\": 0", "\"lvl\": 0");
        std::fs::write(&template_path, text).unwrap();
        assert!(sign(&template_path, &key_path, None, None, 1_762_000_000)
            .unwrap_err()
            .starts_with("roster_invalid:"));

        // A duplicate node id.
        template(&template_path, &fleet, vec![member.node.clone(), member.node.clone()]);
        assert!(sign(&template_path, &key_path, None, None, 1_762_000_000)
            .unwrap_err()
            .starts_with("roster_invalid:"));

        // A missing key file is an error, never a freshly minted identity.
        template(&template_path, &fleet, vec![member.node.clone()]);
        assert!(sign(&template_path, &dir.join("absent.key"), None, None, 1_762_000_000)
            .unwrap_err()
            .starts_with("fleet_key_unusable:"));
        // An expiry of zero days (or a century) is a mistake.
        assert!(sign(&template_path, &key_path, None, Some(0), 1_762_000_000).is_err());
        assert!(
            sign(&template_path, &key_path, None, Some(MAX_EXPIRY_DAYS + 1), 1_762_000_000).is_err()
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn show_without_a_key_says_why_it_cannot_verify() {
        let dir = testkit::temp_dir("show-nokey");
        let (fleet, key_path) = key_at(&dir);
        let member = testkit::Member::new("laptop", 0, &[]);
        let roster = Draft {
            fleet: "ohana".into(),
            issued_at: 1_762_000_000,
            expires_at: 0,
            nodes: vec![member.node.clone()],
        }
        .sign(&fleet);
        let path = dir.join("roster.json");
        std::fs::write(&path, serde_json::to_string(&roster).unwrap()).unwrap();
        let shown = show(&path, None, "", 1_762_000_100).unwrap();
        assert!(!shown.verified);
        assert!(shown.reason.starts_with("roster_key_missing"));
        assert_eq!(shown.entries[0].level, 0, "the levels are still printed");
        // The key may be a file holding the private key: its public half is derived, never printed.
        let shown = show(&path, Some(key_path.to_str().unwrap()), "", 1_762_000_100).unwrap();
        assert!(shown.verified, "{}", shown.reason);
        assert!(shown.key_source.contains("public half"));
        // A key argument that is neither hex nor a key file is refused, not guessed at.
        assert!(show(&path, Some("not-a-key"), "", 1_762_000_100).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_cli_runs_only_its_three_subcommands_and_fails_a_bad_roster() {
        // `run` answers `None` for `push-roster`, which the Lua CLI owns.
        assert!(run(&["fleet".into(), "push-roster".into(), "nextcloud".into()]).is_none());
        assert_eq!(
            run(&["fleet".into(), "keygen".into()]).unwrap(),
            2,
            "keygen without --out is a usage error, not a key somewhere unexpected"
        );
        let dir = testkit::temp_dir("cli");
        let out = dir.join("fleet.key").to_string_lossy().to_string();
        assert_eq!(run(&["fleet".into(), "keygen".into(), "--out".into(), out.clone()]).unwrap(), 0);
        assert_eq!(run(&["fleet".into(), "keygen".into(), "--out".into(), out]).unwrap(), 1);
        // A roster that does not parse exits 1 (the answer, printed, says why).
        let path = dir.join("bad.json").to_string_lossy().to_string();
        std::fs::write(&path, "{}").unwrap();
        assert_eq!(run(&["fleet".into(), "show".into(), path]).unwrap(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
