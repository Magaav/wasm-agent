//! Bounded stores for one component's leftovers: logs, telemetry, replays.
//!
//! Three pieces, each bounded so that no component can fill a node:
//!
//! * [`BoundedDir`] — a directory with a byte quota. `write` evicts the **oldest unpinned** file
//!   until the new one fits; `pin` (an incident, a replay under investigation) marks a file that is
//!   never evicted but is counted and reported; `usage` reports bytes, files, pinned bytes and
//!   whether the quota threshold (80 % by default) is crossed; `expire` drops unpinned files older
//!   than a max age.
//! * [`BlobStore`] — content-addressed (sha256) blobs, written once, reference-counted by the
//!   records that point at them, garbage-collected after a TTL when nothing references or pins them.
//! * [`RecordRing`] — the in-memory ring of host-call records for one component, bounded by bytes
//!   **and** age. Large payloads spill into the blob store by reference, so a ring of 20 MB cannot
//!   hold a 20 MB message body.
//!
//! [`replay::save`] persists whatever the ring holds into one zstd-compressed, versioned file inside
//! a [`BoundedDir`], and [`ReplayReader`] reads records back and resolves blob references — what a
//! replaying host feeds to a component instead of real host results. Format: [`replay`] module docs.
//!
//! Design rules that shaped the API:
//!
//! * **No wasmtime, no async, no globals.** A pure library over `std::fs`, so the kernel can call it
//!   from a component run, a service thread or a `wa` subcommand alike.
//! * **Time is an argument.** Nothing here reads the clock: `write_stamped`, `expire`, `gc`, `save`
//!   take the time they should use. The ring's own timestamps come from the caller too. That is what
//!   makes expiry and eviction testable without sleeping.
//! * **Quota failures are errors, never silent loss.** A write that cannot fit is refused with
//!   [`Error::QuotaExceeded`]; nothing is deleted to make room for something that then fails.
//! * **One writer per directory.** There is no cross-process lock: the kernel is the writer (the
//!   intent is one store per component, owned by the host).

use std::fmt;

pub mod blob;
pub mod dir;
pub mod replay;
pub mod ring;
#[cfg(test)]
mod tests;

pub use blob::{BlobKey, BlobRef, BlobStore, GcReport};
pub use dir::{BoundedDir, Entry, Usage};
pub use replay::{save, Replay, ReplayHeader, ReplayReader, SaveOptions, SavedReplay, Trigger};
pub use ring::{NewRecord, Payload, Record, RecordRing, RingConfig};

/// Default caps, one place, so the kernel and the docs cannot drift apart (docs/REPLAY.md).
pub mod caps {
    use std::time::Duration;

    /// Ring cap: the last five minutes of host calls…
    pub const RING_MAX_AGE: Duration = Duration::from_secs(300);
    /// …or 20 MB, whichever is hit first.
    pub const RING_MAX_BYTES: u64 = 20 * 1024 * 1024;
    /// A payload larger than this is spilled into the blob store instead of the ring.
    pub const BLOB_THRESHOLD_BYTES: u64 = 4 * 1024;
    /// Per-node replay directory quota.
    pub const REPLAY_QUOTA_BYTES: u64 = 500 * 1024 * 1024;
    /// Replay files older than this are expired unless pinned.
    pub const REPLAY_MAX_AGE: Duration = Duration::from_secs(7 * 24 * 3600);
    /// An unreferenced, unpinned blob dies after this.
    pub const BLOB_TTL: Duration = Duration::from_secs(24 * 3600);
    /// `BoundedDir` reports (and fires its callback) at this percentage of the quota.
    pub const THRESHOLD_PCT: u8 = 80;
}

pub type Result<T> = std::result::Result<T, Error>;

/// Every way a bounded store can refuse work.
#[derive(Debug)]
pub enum Error {
    Io(std::io::Error),
    /// A file/blob name that would escape the directory or collide with a marker.
    BadName(String),
    /// A record field (interface, function) that is empty or too long to be a name.
    BadField(&'static str),
    /// The write does not fit: `used + needed > quota` even after evicting every unpinned file.
    QuotaExceeded { needed: u64, used: u64, quota: u64 },
    /// The blob or file does not exist.
    NotFound(String),
    /// The blob the record points at is gone: the replay can be read but not resolved.
    BlobMissing(BlobKey),
    /// A replay file that is not ours, is truncated, has an unknown version, or fails its own
    /// checksum. Never guessed at: a replay that cannot be trusted is refused whole.
    Corrupt(String),
    /// A replay written by a newer format than this crate reads.
    UnsupportedVersion(u16),
    /// A lock was poisoned by a panic in another thread while mutating the refcount index.
    Poisoned,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Io(e) => write!(f, "io: {e}"),
            Error::BadName(n) => write!(f, "bad name: {n:?}"),
            Error::BadField(k) => write!(f, "bad field: {k}"),
            Error::QuotaExceeded { needed, used, quota } => {
                write!(f, "quota exceeded: need {needed} more, {used}/{quota} in use")
            }
            Error::NotFound(n) => write!(f, "not found: {n:?}"),
            Error::BlobMissing(k) => write!(f, "blob missing: {k}"),
            Error::Corrupt(why) => write!(f, "corrupt replay: {why}"),
            Error::UnsupportedVersion(v) => write!(f, "unsupported replay format version {v}"),
            Error::Poisoned => write!(f, "refcount index lock poisoned"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}
