//! Component state: schema versions, never-rewritten migrations, snapshots.
//!
//! Every component on `wa:kernel` owns one kv namespace (`wa:kernel/kv`, `storage` grant). This
//! crate is the host-independent part of keeping that namespace safe across upgrades and across
//! nodes: a **schema version** stored inside the namespace, a registry of **vN -> vN+1** steps that
//! are never edited once shipped, a **journal** that lets a migration resume after a crash, and a
//! **snapshot** format for backup and node moves.
//!
//! Design rules, in the order they constrain the code:
//!
//! - The library is pure: it owns no clock, no paths and no wasmtime. `get/put/del/scan_prefix`
//!   arrive through [`Kv`], the clock is a parameter, snapshots are written to any [`std::io::Write`].
//!   That is what lets the same code run over the host's SQLite-backed kv and over [`MemKv`] in
//!   tests, and it keeps the host free to decide where a namespace lives.
//! - Meta keys live under the reserved prefix [`meta::RESERVED_PREFIX`] (`__wa/`). A component never
//!   sees or writes them: [`UserView`] hides them and refuses writes, so a component cannot forge
//!   its own schema version. The migrator is the only writer, and a migration step's [`Batch`]
//!   cannot address them either.
//! - A step is a pure function over a batch ([`Batch`]), not over the store. A step that reads the
//!   store directly cannot be replayed, and replay is the whole point: a crash mid-migration must
//!   end with exactly the state an uninterrupted run produces. Steps compute the whole next batch in
//!   memory, then the engine diffs it, journals the *full values* it is about to write, and only
//!   then applies them. Re-applying a journaled put or delete is therefore idempotent.
//! - The schema version moves with one atomic put, one step at a time, and only after every change
//!   of that step is on disk. A resumed run finishes the journaled step (the step function is not
//!   called again) and continues forward. It never applies a journaled step backwards.
//! - Downgrades are refused unless the caller allows them **and** every step on the way down
//!   registered a `down` function. There is no "the up function probably works in reverse".
//! - A snapshot is versioned, checksummed (sha256 over the uncompressed payload) and zstd-compressed,
//!   and it carries the component id + pin (sha256) that produced the data. Import verifies all of
//!   that before it writes one key.
//!
//! What this crate deliberately does not do: it does not decide *when* a migration runs (the host's
//! transactional install does, see `docs/STATE.md`), it does not open files or databases, and it
//! does not migrate between component ids - a namespace has one owner.
//!
//! `docs/STATE.md` is the rule book: which version moves when, where a migration ships, and the
//! install sequence the kernel has to run around it.
//!
//! Features: the default `snapshot` feature adds the zstd-compressed file format (`export`/`import`),
//! which is host- or sidecar-side. `default-features = false` leaves the migration core, which is
//! what a component that migrates its own namespace inside a wasm guest needs (verified to compile
//! for `wasm32-wasip2`; the codec is not, because `zstd-sys` compiles C).

use std::fmt;

pub mod batch;
pub mod kv;
pub mod meta;
pub mod migrate;
pub mod snapshot;

pub use batch::{Batch, Change, ChangeCounts};
pub use kv::{Kv, MemKv, UserView};
pub use meta::{ComponentInfo, Meta};
pub use migrate::{
    journal, Direction, Journal, MigrateOptions, MigrationReport, Migrator, PendingStep, Registry,
    SnapshotSink, Step, StepReport,
};
pub use snapshot::{ExportOptions, ImportOptions, Snapshot, SnapshotHeader};
#[cfg(feature = "snapshot")]
pub use snapshot::{export, import, verify};

#[cfg(test)]
mod tests;

/// Everything this crate refuses, with a reason that is safe to log: keys are never included,
/// because a key is component data (a chat id, a file name) and logs must not carry it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The store itself failed (I/O, SQLite, a closed handle).
    Kv(String),
    /// A file or record we wrote cannot be understood: wrong magic, truncated, inconsistent header.
    Format(String),
    /// Bytes inside a namespace do not parse as what they claim to be.
    Corrupt(String),
    /// A snapshot's payload does not hash to the checksum it carries.
    ChecksumMismatch { expected: String, found: String },
    /// The snapshot (or the namespace) is at a different schema version than required.
    SchemaVersionMismatch { expected: u32, found: u32 },
    /// The namespace belongs to another component.
    OwnerMismatch { expected: String, found: String },
    /// The snapshot was produced by another component build than the one required.
    ComponentMismatch { expected: String, found: String },
    /// A downgrade was asked for without `allow_downgrade`.
    DowngradeRefused { from: u32, to: u32 },
    /// No registered step covers one version on the path.
    NoMigrationPath {
        from: u32,
        to: u32,
        missing: u32,
        direction: Direction,
    },
    /// A write tried to touch the host-owned `__wa/` meta keys.
    Reserved,
    /// The namespace already holds keys but no metadata: refusing to adopt foreign data.
    Uninitialised { keys: usize },
    /// Import into a namespace that already holds keys, without an explicit replace.
    NotEmpty { keys: usize },
    /// A bound we will not cross (batch size, snapshot size, key/value size, journal size).
    Limit {
        what: &'static str,
        limit: u64,
        found: u64,
    },
    /// The migration journal and the schema version disagree: only the last snapshot can settle it.
    JournalInconsistent(String),
    /// Fault injection in [`MemKv`]: a test crash.
    Injected(&'static str),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Kv(why) => write!(f, "kv: {why}"),
            Error::Format(why) => write!(f, "format: {why}"),
            Error::Corrupt(why) => write!(f, "corrupt: {why}"),
            Error::ChecksumMismatch { expected, found } => {
                write!(f, "snapshot checksum mismatch: expected {expected}, found {found}")
            }
            Error::SchemaVersionMismatch { expected, found } => {
                write!(f, "schema version mismatch: expected v{expected}, found v{found}")
            }
            Error::OwnerMismatch { expected, found } => {
                write!(f, "namespace belongs to component {found}, not {expected}")
            }
            Error::ComponentMismatch { expected, found } => {
                write!(f, "snapshot pin mismatch: expected {expected}, found {found}")
            }
            Error::DowngradeRefused { from, to } => {
                write!(f, "refusing to downgrade state from v{from} to v{to}")
            }
            Error::NoMigrationPath { from, to, missing, direction } => write!(
                f,
                "no {} step registered for v{missing} (path v{from} -> v{to})",
                match direction {
                    Direction::Up => "up",
                    Direction::Down => "down",
                }
            ),
            Error::Reserved => write!(f, "the __wa/ meta keys are host-owned"),
            Error::Uninitialised { keys } => write!(
                f,
                "{keys} keys are present without schema metadata; refusing to adopt them"
            ),
            Error::NotEmpty { keys } => {
                write!(f, "namespace already holds {keys} keys; import needs replace")
            }
            Error::Limit { what, limit, found } => {
                write!(f, "{what} is {found} bytes, above the {limit} byte limit")
            }
            Error::JournalInconsistent(why) => write!(f, "migration journal inconsistent: {why}"),
            Error::Injected(why) => write!(f, "injected fault: {why}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Error::Kv(error.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;

/// Key and value sizes the host's `wa_kv` grant enforces (`rust/wa-kernel-runtime/src/services.rs`). A
/// migration or an import checks them *before* it writes, so a value the host would refuse can
/// never leave a half-applied step behind.
pub const MAX_KEY_BYTES: u64 = 4096;
pub const MAX_VALUE_BYTES: u64 = 16 << 20;

pub(crate) fn check_size(key: &[u8], value: Option<&[u8]>) -> Result<()> {
    if key.len() as u64 > MAX_KEY_BYTES {
        return Err(Error::Limit {
            what: "key",
            limit: MAX_KEY_BYTES,
            found: key.len() as u64,
        });
    }
    if let Some(value) = value {
        if value.len() as u64 > MAX_VALUE_BYTES {
            return Err(Error::Limit {
                what: "value",
                limit: MAX_VALUE_BYTES,
                found: value.len() as u64,
            });
        }
    }
    Ok(())
}
