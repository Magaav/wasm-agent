//! `wa vault ...` — the operator's terminal.
//!
//! Two rules shape this file, and both are about the value never landing somewhere it can be read
//! later:
//!
//! 1. **A value is never an argument.** `set`, `rotate` and `sign` read their input from `--from <path>`
//!    or `--stdin`; there is no positional value form, because a shell history, a process listing and
//!    a terminal scrollback are all places a secret is copied to for free.
//! 2. **Only `reveal` prints a value.** Every other command prints names, versions, protection, paths
//!    and reason words. `wa vault sign` prints the *signature*; the seed stays in the vault.
//!
//! `--dir` (or `WASM_AGENT_VAULT_DIR`) is required. The command refuses to guess a vault directory, so
//! a test in a temp directory can never reach a node's real vault by being run in the wrong place.
//!
//! Wiring: `--route` free dispatch is `run(args)`; the node binary calls it from `main.rs` for
//! `wa vault`. Until that line lands (it is owned by the `wa-host` stream), `cargo run -p wa-vault
//! --bin wa-vault -- <args>` is the same code.
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::migrate;
use crate::policy::Policy;
use crate::store::FileStore;
use crate::{Actor, Kind, Vault, VaultOptions};

/// Where the vault directory comes from. An unset directory is a refusal, never a default.
pub const DIR_ENV: &str = "WASM_AGENT_VAULT_DIR";

pub fn run(args: &[String]) -> Option<i32> {
    let mut rest = args;
    if rest.first().map(String::as_str) == Some("vault") {
        rest = &rest[1..];
    }
    match dispatch(rest) {
        Ok(()) => Some(0),
        Err(error) => {
            eprintln!("vault: {error}");
            Some(1)
        }
    }
}

fn dispatch(args: &[String]) -> Result<(), String> {
    let options = Flags::parse(args)?;
    let command = options.command.as_str();
    match command {
        "" | "help" | "--help" | "-h" => {
            println!("{USAGE}");
            Ok(())
        }
        "status" => {
            let (keystore, _) = open_keystore(&options)?;
            let status = keystore.status();
            println!("vault: {}", keystore.dir().display());
            println!("root: {}", if status.root { "present" } else { "missing" });
            println!("protection: {}", status.protection.as_str());
            Ok(())
        }
        "list" => {
            let vault = open_vault(&options)?;
            let entries = vault.list();
            if entries.is_empty() {
                println!("vault: empty");
            }
            for (name, meta) in entries {
                println!(
                    "{name}\t{}\tversion {}\tcreated {}\trotated {}\towner {}",
                    meta.kind.as_str(),
                    meta.version,
                    meta.created,
                    meta.rotated_at,
                    meta.owner
                );
            }
            Ok(())
        }
        "show" => {
            let name = options.required(0)?;
            let vault = open_vault(&options)?;
            let meta = vault.get_meta(&name).ok_or_else(|| "vault_unknown_entry".to_string())?;
            println!("name: {name}");
            println!("kind: {}", meta.kind.as_str());
            println!("version: {}", meta.version);
            println!("created: {}", meta.created);
            println!("rotated_at: {}", meta.rotated_at);
            println!("owner: {}", meta.owner);
            println!("allowed: {}", meta.allowed.join(","));
            Ok(())
        }
        "set" => {
            let name = options.required(0)?;
            let kind = match options.flag("--kind").unwrap_or_else(|| "secret".to_string()).as_str() {
                "secret" => Kind::Secret,
                "ed25519" => Kind::Ed25519,
                other => return Err(format!("kind_unknown:{other}")),
            };
            let value = read_value(&options)?;
            let mut vault = open_vault(&options)?;
            let actor = operator_actor();
            let meta = vault.set(&name, kind, &value, &actor)?;
            println!("{name}: {} version {}", meta.kind.as_str(), meta.version);
            Ok(())
        }
        "rotate" => {
            let name = options.required(0)?;
            let replacement = read_value(&options).ok();
            let mut vault = open_vault(&options)?;
            let meta = vault.rotate(&name, &operator_actor(), replacement.as_deref())?;
            println!("{name}: version {} (previous kept for {}s)", meta.version, vault.rotation_window());
            Ok(())
        }
        "delete" => {
            let name = options.required(0)?;
            let mut vault = open_vault(&options)?;
            vault.delete(&name, &operator_actor())?;
            println!("{name}: deleted");
            Ok(())
        }
        "reveal" => {
            let name = options.required(0)?;
            let mut vault = open_vault(&options)?;
            let value = vault.reveal(&name, &operator_actor())?;
            // The one command that writes a value out, to the operator's own terminal.
            use std::io::Write;
            std::io::stdout()
                .write_all(&value)
                .map_err(|error| format!("stdout:{error}"))?;
            println!();
            Ok(())
        }
        "public-key" => {
            let name = options.required(0)?;
            let vault = open_vault(&options)?;
            println!("{}", crate::hex::encode(&vault.public_key(&name)?));
            Ok(())
        }
        "sign" => {
            let name = options.required(0)?;
            let message = read_value(&options)?;
            let mut vault = open_vault(&options)?;
            let signature = vault.sign(&name, &operator_actor(), &message)?;
            println!("{}", crate::hex::encode(&signature));
            Ok(())
        }
        "import-ed25519" => {
            let name = options.required(0)?;
            let path = options.flag("--from").ok_or_else(|| "flag_required:--from".to_string())?;
            let bytes = std::fs::read(&path).map_err(|error| format!("read_seed:{error}"))?;
            // The operator's own tooling decides the file format (`wa fleet keygen` writes pkcs8 hex,
            // `node.key` too, a hand-made key may be 32 raw bytes): `seed::read` accepts what an
            // operator actually has and names what it read.
            let (seed, format) = crate::seed::read(&bytes)?;
            let mut vault = open_vault(&options)?;
            let actor = operator_actor();
            let meta = vault.import_ed25519(&name, &seed, &actor)?;
            println!("{name}: ed25519 version {} (read as {})", meta.version, format.as_str());
            println!("public_key: {}", crate::hex::encode(&vault.public_key(&name)?));
            if options.has("--shred") {
                shred(Path::new(&path))?;
                // The chain is what an operator reads afterwards to see that the source file is gone
                // (`wa vault audit tail`); the line says which entry and which name, never a value.
                vault.note("shred-source", &actor, &name, meta.version, "ok")?;
                println!("source: shredded ({path})");
            } else {
                println!("source: kept ({path}); pass --shred to destroy it after verification");
            }
            Ok(())
        }
        "import-provider-keys" => {
            let dir = options
                .flag("--from")
                .map(PathBuf::from)
                .ok_or_else(|| "flag_required:--from".to_string())?;
            let mut vault = open_vault(&options)?;
            let report = migrate::import_keys(&mut vault, &dir, &operator_actor())?;
            for line in report.lines() {
                println!("{line}");
            }
            Ok(())
        }
        "audit" => {
            let sub = options.required(0)?;
            match sub.as_str() {
                "verify" => {
                    let vault = open_vault(&options)?;
                    match vault.verify_audit() {
                        Ok(count) => {
                            println!("audit: verified {count} lines");
                            Ok(())
                        }
                        Err(error) => Err(error.reason().to_string()),
                    }
                }
                "tail" => {
                    let lines = options
                        .flag("--lines")
                        .and_then(|value| value.parse::<usize>().ok())
                        .unwrap_or(20);
                    let vault = open_vault(&options)?;
                    let log = vault.audit_lines();
                    for line in log.iter().skip(log.len().saturating_sub(lines)) {
                        println!("{line}");
                    }
                    Ok(())
                }
                other => Err(format!("audit_subcommand_unknown:{other}")),
            }
        }
        other => Err(format!("subcommand_unknown:{other}")),
    }
}

const USAGE: &str = "\
usage: wa vault <command> [--dir <vault-dir|$WASM_AGENT_VAULT_DIR>] [--policy <policy.json>]

The node's own `wa vault` defaults --dir to <home>/.wasm-agent/vault. The standalone
`wa-vault` binary requires it: an unset directory is a refusal, never a guess.

  status                      where the vault is and how its root key is protected
  list                        names and metadata (never a value)
  show <name>                 one entry's metadata
  set <name> [--kind secret|ed25519] [--from <path>|--stdin]
  rotate <name> [--from <path>|--stdin]
  delete <name>
  reveal <name>               print the value (the only command that does)
  public-key <name>           the ed25519 public key of an ed25519 entry
  sign <name> [--from <path>|--stdin]
  import-ed25519 <name> --from <path> [--shred]
                              a 32-byte seed, 64 hex characters, or the pkcs8 hex that
                              `wa fleet keygen` and node.key hold; --shred zeroes and
                              removes the source after the entry verified, and the audit
                              chain records that it did
  import-provider-keys --from <keys-dir>
  audit verify | audit tail [--lines N]";

fn operator_actor() -> Actor {
    let user = std::env::var("USERNAME")
        .or_else(|_| std::env::var("USER"))
        .unwrap_or_else(|_| "operator".to_string());
    Actor::Operator(user)
}

/// Read a value from `--from`/`--stdin`. There is no third way, on purpose.
fn read_value(options: &Flags) -> Result<Vec<u8>, String> {
    let bytes = match (options.flag("--from"), options.has("--stdin")) {
        (Some(path), _) => std::fs::read(&path).map_err(|error| format!("read_value:{error}"))?,
        (None, true) => {
            let mut buffer = Vec::new();
            std::io::stdin()
                .read_to_end(&mut buffer)
                .map_err(|error| format!("read_stdin:{error}"))?;
            buffer
        }
        (None, false) => return Err("value_required:--from <path> or --stdin".to_string()),
    };
    // A trailing newline from an editor or a pipe is not part of the value; anything else is.
    Ok(match bytes.strip_suffix(b"\n") {
        Some(stripped) => stripped.to_vec(),
        None => bytes,
    })
}

/// Overwrite the source with zeros before removing it. This is `--shred`'s documented "best effort":
/// on a copy-on-write filesystem or an SSD's wear levelling the original blocks may still hold the
/// bytes, and saying so is more useful than implying a guarantee the platform cannot give.
fn shred(path: &Path) -> Result<(), String> {
    let length = std::fs::metadata(path).map_err(|error| format!("shred_stat:{error}"))?.len();
    {
        use std::io::{Seek, SeekFrom, Write};
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .open(path)
            .map_err(|error| format!("shred_open:{error}"))?;
        file.seek(SeekFrom::Start(0)).map_err(|error| format!("shred_seek:{error}"))?;
        let zeros = vec![0u8; 4096.min(length.max(1) as usize)];
        let mut written = 0u64;
        while written < length {
            let chunk = (length - written).min(zeros.len() as u64) as usize;
            file.write_all(&zeros[..chunk]).map_err(|error| format!("shred_write:{error}"))?;
            written += chunk as u64;
        }
        file.sync_all().map_err(|error| format!("shred_sync:{error}"))?;
    }
    std::fs::remove_file(path).map_err(|error| format!("shred_remove:{error}"))
}

fn vault_dir(options: &Flags) -> Result<PathBuf, String> {
    if let Some(dir) = options.flag("--dir") {
        return Ok(PathBuf::from(dir));
    }
    match std::env::var(DIR_ENV) {
        Ok(dir) if !dir.trim().is_empty() => Ok(PathBuf::from(dir)),
        _ => Err(format!("vault_dir_unset: pass --dir or set {DIR_ENV}")),
    }
}

fn open_keystore(options: &Flags) -> Result<(Arc<wa_keystore::Keystore>, PathBuf), String> {
    let dir = vault_dir(options)?;
    let mut keystore = wa_keystore::Keystore::open(&wa_keystore::Options::from_env(&dir))
        .map_err(|error| error.reason().to_string())?;
    keystore.ensure_root().map_err(|error| error.reason().to_string())?;
    // ONE line, once per command, and only when the protection that was taken is not the one this host
    // would have preferred: `keystore_keyring_refused:edquot, using the passphrase file` when the uid's
    // kernel-keyring quota is spent (the machine state that failed three vault rows inside the fast path,
    // 13/11), or `keystore_protection_from_file:passphrase, …` when the root file on disk decided instead
    // of the environment. A downgrade an operator cannot see is a downgrade nobody can fix.
    if let Some(note) = keystore.note() {
        eprintln!("vault: {note}");
    }
    Ok((Arc::new(keystore), dir))
}

fn open_policy(options: &Flags) -> Result<Policy, String> {
    match options.flag("--policy") {
        Some(path) => {
            let text = std::fs::read_to_string(&path).map_err(|error| format!("policy_read:{error}"))?;
            Policy::from_policy_json(&text).map_err(|error| error.to_string())
        }
        None => Ok(Policy::default()),
    }
}

pub fn open_vault(options: &Flags) -> Result<Vault, String> {
    let (keystore, dir) = open_keystore(options)?;
    let policy = open_policy(options)?;
    let sealer = keystore.for_namespace("vault");
    let store = FileStore::new(&dir);
    let mut vault = Vault::open(
        Box::new(sealer),
        Box::new(store),
        VaultOptions { policy, owner: operator_actor().id(), ..VaultOptions::default() },
    )
    .map_err(|error| error.to_string())?;
    // Rotation's destruction half: a node that never rotates again still destroys old material on the
    // next start.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .unwrap_or(0);
    vault.purge_expired(now).map_err(|error| error.to_string())?;
    Ok(vault)
}

/// The tiny flag reader. `--flag value` and `--flag` (boolean) both work; a positional argument is a
/// value for `required(n)`.
pub struct Flags {
    pub command: String,
    positional: Vec<String>,
    flags: Vec<(String, Option<String>)>,
}

impl Flags {
    pub fn parse(args: &[String]) -> Result<Self, String> {
        let mut command = String::new();
        let mut positional = Vec::new();
        let mut flags: Vec<(String, Option<String>)> = Vec::new();
        let mut index = 0;
        while index < args.len() {
            let argument = &args[index];
            if let Some(name) = argument.strip_prefix("--") {
                if name.is_empty() {
                    return Err("flag_invalid:--".to_string());
                }
                // A boolean flag is one with no following value, or one followed by another flag.
                let next = args.get(index + 1);
                match next {
                    Some(value) if !value.starts_with("--") && !is_flag_name(name) => {
                        flags.push((format!("--{name}"), Some(value.clone())));
                        index += 2;
                    }
                    _ => {
                        flags.push((format!("--{name}"), None));
                        index += 1;
                    }
                }
                continue;
            }
            if command.is_empty() {
                command = argument.clone();
            } else {
                positional.push(argument.clone());
            }
            index += 1;
        }
        Ok(Flags { command, positional, flags })
    }

    pub fn required(&self, index: usize) -> Result<String, String> {
        self.positional
            .get(index)
            .cloned()
            .ok_or_else(|| "argument_required".to_string())
    }

    pub fn has(&self, name: &str) -> bool {
        self.flags.iter().any(|(flag, _)| flag == name)
    }

    pub fn flag(&self, name: &str) -> Option<String> {
        self.flags
            .iter()
            .find(|(flag, _)| flag == name)
            .and_then(|(_, value)| value.clone())
    }
}

/// Flags that never take a value even when a word follows them.
fn is_flag_name(name: &str) -> bool {
    matches!(name, "stdin" | "shred" | "yes" | "help")
}
