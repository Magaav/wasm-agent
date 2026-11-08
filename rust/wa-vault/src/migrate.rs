//! Migrating the keys an older node keeps in `<home>/keys/*.key` into the vault.
//!
//! `docs/VAULT.md` says provider keys migrate **on first start, idempotently, and the original is kept
//! until the new entry is verified**. This module is that sentence, and it is deliberately the most
//! conservative code in the crate:
//!
//! * a name that already exists with a **different** value is refused, never overwritten: an operator
//!   decides which of the two is real, not a start-up path;
//! * a name that already exists with the **same** value is reported `kept` - that is what makes a
//!   second start a no-op rather than a second write;
//! * the source file is never modified or removed here. Shredding the source is an explicit operator
//!   request (`wa vault import-ed25519 --shred`), and only after the entry verified;
//! * the report carries names and reason words, never a value.
use std::path::Path;

use crate::{Actor, Kind, Result, Vault, VaultError};

/// What a migration did, per name. Names only.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Migration {
    /// Migrated now (the value was not in the vault).
    pub imported: Vec<String>,
    /// Already in the vault with the same value: nothing was written.
    pub kept: Vec<String>,
    /// `(name, reason)`: the vault has a different value, or the file could not be read.
    pub refused: Vec<(String, String)>,
}

impl Migration {
    pub fn is_clean(&self) -> bool {
        self.refused.is_empty()
    }

    /// One line per name, for the node log: `imported:github`, `kept:github`, `refused:x:reason`.
    /// The format is stable because the operator-facing report is built from it.
    pub fn lines(&self) -> Vec<String> {
        let mut lines = Vec::new();
        for name in &self.imported {
            lines.push(format!("imported:{name}"));
        }
        for name in &self.kept {
            lines.push(format!("kept:{name}"));
        }
        for (name, reason) in &self.refused {
            lines.push(format!("refused:{name}:{reason}"));
        }
        lines
    }
}

/// Read every `*.key` in `keys_dir` and put it in the vault. The caller decides whether the directory
/// exists: a node with no legacy keys passes a path that may not exist, and that is not an error.
pub fn import_keys(vault: &mut Vault, keys_dir: &Path, actor: &Actor) -> Result<Migration> {
    let mut report = Migration::default();
    let entries = match std::fs::read_dir(keys_dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(report),
        Err(error) => return Err(VaultError(format!("migration_dir:{error}"))),
    };
    let mut names: Vec<_> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| path.extension().map(|extension| extension == "key").unwrap_or(false))
        .collect();
    // Sorted, so a migration is reproducible and its report does not depend on directory order.
    names.sort();
    for path in names {
        let Some(name) = path.file_stem().and_then(|stem| stem.to_str()).map(str::to_string) else {
            continue;
        };
        match migrate_one(vault, &name, &path, actor) {
            Ok(Outcome::Imported) => report.imported.push(name),
            Ok(Outcome::Kept) => report.kept.push(name),
            Ok(Outcome::Refused(reason)) => report.refused.push((name, reason)),
            Err(error) => report.refused.push((name, error.reason().to_string())),
        }
    }
    Ok(report)
}

enum Outcome {
    Imported,
    Kept,
    Refused(String),
}

fn migrate_one(vault: &mut Vault, name: &str, path: &Path, actor: &Actor) -> Result<Outcome> {
    // A key file is one value, trimmed of the trailing newline an editor adds. Trailing whitespace
    // inside a token is not trimmed: a value with a space is a value the operator typed.
    let raw = std::fs::read(path).map_err(|error| VaultError(format!("migration_read:{error}")))?;
    let value = match raw.strip_suffix(b"\n") {
        Some(stripped) => stripped.to_vec(),
        None => raw,
    };
    if value.is_empty() {
        return Ok(Outcome::Refused("empty_key_file".to_string()));
    }
    if let Some(meta) = vault.get_meta(name) {
        if meta.kind != Kind::Secret {
            return Ok(Outcome::Refused("kind_mismatch".to_string()));
        }
        return Ok(if vault.value_matches(name, &value) {
            Outcome::Kept
        } else {
            Outcome::Refused("vault_entry_differs".to_string())
        });
    }
    vault.set(name, Kind::Secret, &value, actor)?;
    // Verified before the caller is told it imported anything: `set` succeeded, but the promise is
    // that the *readable* entry matches the source file.
    if !vault.value_matches(name, &value) {
        return Ok(Outcome::Refused("verify_failed".to_string()));
    }
    Ok(Outcome::Imported)
}
