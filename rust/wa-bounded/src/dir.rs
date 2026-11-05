//! A directory with a byte quota: oldest-unpinned-first eviction, pins, a threshold and expiry.
//!
//! Layout: payload files live **directly** in the root under a validated name; a zero-byte
//! companion `<name>.pin` marks one as pinned. Companion markers, `*.tmp` staging files and
//! subdirectories are not payload: they are never listed, counted or evicted, so the same
//! `BoundedDir` may hold a nested blob store (see [`crate::BlobStore`]) without the quota accounting
//! getting confused about files it does not own. A marker is a few bytes on disk that the quota
//! deliberately does not charge for; the accounting is otherwise exact.
//!
//! Eviction order is file mtime, oldest first, name as the tiebreak — so it survives a restart and
//! needs no index to stay consistent. A write that cannot fit after every unpinned file has gone is
//! refused with [`Error::QuotaExceeded`], and nothing is written.
//!
//! Writes are atomic: bytes go to `.<name>.<pid>.tmp`, get their mtime set, and are renamed over the
//! target. A reader (or a crash) never sees a half-written file.

use crate::{caps, Error, Result};
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

/// Companion marker suffix: `<name>.pin` marks `<name>` as pinned.
const PIN_SUFFIX: &str = ".pin";
/// Staging suffix for atomic writes; never listed, never counted.
const TMP_SUFFIX: &str = ".tmp";
const MAX_NAME: usize = 200;

/// The threshold hook: called with the usage at the moment of the crossing.
pub type ThresholdHook = Box<dyn Fn(&Usage) + Send + Sync>;

/// Is `name` usable as a payload file name? Flat, no separators, no `..`, no leading dot (so a name
/// can never look like a staging file), no `.pin`/`.tmp` suffix (so it can never collide with a
/// marker), bounded length, ASCII alphanumerics plus `-_.`.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_NAME
        && !name.starts_with('.')
        && !name.contains("..")
        && !name.ends_with(PIN_SUFFIX)
        && !name.ends_with(TMP_SUFFIX)
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// What one file in the directory is, as the quota sees it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub bytes: u64,
    pub ts: SystemTime,
    pub pinned: bool,
}

/// The directory's usage, in the shape the kernel logs and the operator sees.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Usage {
    pub bytes: u64,
    pub quota: u64,
    pub files: u64,
    /// Bytes held by pinned files. Always counted in `bytes`; never a candidate for eviction.
    pub pinned_bytes: u64,
    pub pinned_files: u64,
    pub threshold_pct: u8,
}

impl Usage {
    pub fn remaining(&self) -> u64 {
        self.quota.saturating_sub(self.bytes)
    }
    /// Pinned files already pushed the directory past its quota. Not an error by itself: the pin is
    /// the point (an incident keeps its evidence), but it is reported so the operator can act.
    pub fn over_quota(&self) -> bool {
        self.bytes > self.quota
    }
    /// Whole percent of the quota in use (a quota of zero reads as 100 % when anything is stored).
    pub fn pct(&self) -> u64 {
        if self.quota == 0 {
            if self.bytes == 0 {
                0
            } else {
                100
            }
        } else {
            ((self.bytes as u128 * 100) / self.quota as u128).min(u64::MAX as u128) as u64
        }
    }
    pub fn over_threshold(&self) -> bool {
        self.quota > 0 && self.bytes as u128 * 100 >= self.quota as u128 * self.threshold_pct as u128
    }
}

/// A directory with a byte quota.
pub struct BoundedDir {
    root: PathBuf,
    quota: u64,
    threshold_pct: u8,
    on_threshold: Option<ThresholdHook>,
    /// Whether the last observed usage was over the threshold: the callback fires on the crossing,
    /// not on every write.
    above: AtomicBool,
}

impl std::fmt::Debug for BoundedDir {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BoundedDir")
            .field("root", &self.root)
            .field("quota", &self.quota)
            .field("threshold_pct", &self.threshold_pct)
            .field("on_threshold", &self.on_threshold.is_some())
            .finish()
    }
}

impl BoundedDir {
    /// Open (creating if needed) a quota directory. `quota == 0` means "nothing may be stored" —
    /// deliberately not "unbounded": a store that refuses to say its limit must not claim one.
    pub fn open(root: impl Into<PathBuf>, quota: u64) -> Result<Self> {
        let root = root.into();
        fs::create_dir_all(&root)?;
        Ok(BoundedDir {
            root,
            quota,
            threshold_pct: caps::THRESHOLD_PCT,
            on_threshold: None,
            above: AtomicBool::new(false),
        })
    }

    /// The percentage of the quota at which `on_threshold` fires and `Usage::over_threshold` is true.
    pub fn with_threshold(mut self, pct: u8) -> Self {
        self.threshold_pct = pct.clamp(1, 100);
        self
    }

    /// Called once each time usage crosses the threshold upward (`&Usage` at the crossing). It is
    /// not called on every write above it: a component that logs 10 000 lines does not get 10 000
    /// warnings, and crossing back below re-arms it.
    pub fn on_threshold<F>(mut self, f: F) -> Self
    where
        F: Fn(&Usage) + Send + Sync + 'static,
    {
        self.on_threshold = Some(Box::new(f));
        self
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn quota(&self) -> u64 {
        self.quota
    }

    pub fn threshold_pct(&self) -> u8 {
        self.threshold_pct
    }

    pub fn path_of(&self, name: &str) -> PathBuf {
        self.root.join(name)
    }

    fn pin_marker(&self, name: &str) -> PathBuf {
        self.root.join(format!("{name}{PIN_SUFFIX}"))
    }

    /// Every payload file, oldest first (mtime, then name).
    pub fn entries(&self) -> Result<Vec<Entry>> {
        let mut out = Vec::new();
        let read = fs::read_dir(&self.root)?;
        for dirent in read {
            let dirent = dirent?;
            if !dirent.file_type()?.is_file() {
                continue; // subdirectories belong to someone else (e.g. a nested blob store)
            }
            let name = dirent.file_name().to_string_lossy().into_owned();
            if name.ends_with(TMP_SUFFIX) || name.ends_with(PIN_SUFFIX) {
                continue;
            }
            let meta = dirent.metadata()?;
            let pinned = self.pin_marker(&name).exists();
            out.push(Entry {
                name,
                bytes: meta.len(),
                ts: meta.modified().unwrap_or(SystemTime::UNIX_EPOCH),
                pinned,
            });
        }
        out.sort_by(|a, b| a.ts.cmp(&b.ts).then_with(|| a.name.cmp(&b.name)));
        Ok(out)
    }

    pub fn usage(&self) -> Result<Usage> {
        let entries = self.entries()?;
        Ok(self.usage_of(&entries))
    }

    fn usage_of(&self, entries: &[Entry]) -> Usage {
        let mut usage = Usage {
            bytes: 0,
            quota: self.quota,
            files: 0,
            pinned_bytes: 0,
            pinned_files: 0,
            threshold_pct: self.threshold_pct,
        };
        for e in entries {
            usage.bytes = usage.bytes.saturating_add(e.bytes);
            usage.files += 1;
            if e.pinned {
                usage.pinned_bytes = usage.pinned_bytes.saturating_add(e.bytes);
                usage.pinned_files += 1;
            }
        }
        usage
    }

    /// Write `bytes` as `name`, evicting the oldest unpinned files until it fits.
    pub fn write(&self, name: &str, bytes: &[u8]) -> Result<()> {
        self.write_stamped(name, bytes, SystemTime::now())
    }

    /// `write`, with the file's mtime given: `ts` is what eviction order and expiry read. Tests (and
    /// a replayed write) pass it; production passes `SystemTime::now()`.
    ///
    /// A **pinned** write is never evicted and is allowed to push the directory over quota: that is
    /// what pinning an incident means. An unpinned write that cannot fit after every unpinned file
    /// is gone is refused, and nothing is deleted for it.
    pub fn write_stamped(&self, name: &str, bytes: &[u8], ts: SystemTime) -> Result<()> {
        if !valid_name(name) {
            return Err(Error::BadName(name.to_string()));
        }
        let size = bytes.len() as u64;
        let pinned = self.is_pinned(name);
        let entries = self.entries()?;
        let replaced = entries.iter().find(|e| e.name == name).map(|e| e.bytes).unwrap_or(0);
        let usage = self.usage_of(&entries);
        let mut used = usage.bytes.saturating_sub(replaced);

        if !pinned && used.saturating_add(size) > self.quota {
            // Check first, delete second: even evicting every unpinned file may not be enough, and a
            // write that is going to be refused must not have destroyed the files that were there.
            let floor = usage.pinned_bytes.saturating_add(size);
            if floor > self.quota {
                return Err(Error::QuotaExceeded { needed: size, used, quota: self.quota });
            }
            for victim in entries.iter().filter(|e| !e.pinned && e.name != name) {
                if used.saturating_add(size) <= self.quota {
                    break;
                }
                fs::remove_file(self.root.join(&victim.name))?;
                let _ = fs::remove_file(self.pin_marker(&victim.name));
                used = used.saturating_sub(victim.bytes);
            }
            if used.saturating_add(size) > self.quota {
                return Err(Error::QuotaExceeded { needed: size, used, quota: self.quota });
            }
        }

        let staging = self.root.join(format!(".{name}.{}{TMP_SUFFIX}", std::process::id()));
        {
            let mut file = fs::File::create(&staging)?;
            file.write_all(bytes)?;
            file.flush()?;
            // Eviction and expiry both read the mtime; setting it before the rename means the file
            // appears with its final age, never with "now".
            file.set_modified(ts)?;
        }
        if let Err(e) = fs::rename(&staging, self.root.join(name)) {
            let _ = fs::remove_file(&staging);
            return Err(e.into());
        }
        self.observe_threshold()?;
        Ok(())
    }

    fn observe_threshold(&self) -> Result<()> {
        let usage = self.usage()?;
        let over = usage.over_threshold() || usage.over_quota();
        let was = self.above.swap(over, Ordering::SeqCst);
        if over && !was {
            if let Some(cb) = &self.on_threshold {
                cb(&usage);
            }
        }
        Ok(())
    }

    pub fn read(&self, name: &str) -> Result<Vec<u8>> {
        if !valid_name(name) {
            return Err(Error::BadName(name.to_string()));
        }
        match fs::read(self.root.join(name)) {
            Ok(bytes) => Ok(bytes),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(Error::NotFound(name.to_string())),
            Err(e) => Err(e.into()),
        }
    }

    pub fn exists(&self, name: &str) -> bool {
        valid_name(name) && self.root.join(name).is_file()
    }

    /// Remove a payload file and its pin marker. `Ok(false)` when it was not there.
    pub fn remove(&self, name: &str) -> Result<bool> {
        if !valid_name(name) {
            return Err(Error::BadName(name.to_string()));
        }
        let _ = fs::remove_file(self.pin_marker(name));
        let removed = match fs::remove_file(self.root.join(name)) {
            Ok(()) => true,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
            Err(e) => return Err(e.into()),
        };
        self.observe_threshold()?;
        Ok(removed)
    }

    /// Mark `name` pinned: never evicted, never expired, still counted. Requires the file to exist,
    /// so a pin cannot be created for nothing and then be mistaken for evidence later.
    pub fn pin(&self, name: &str) -> Result<()> {
        if !valid_name(name) {
            return Err(Error::BadName(name.to_string()));
        }
        if !self.exists(name) {
            return Err(Error::NotFound(name.to_string()));
        }
        fs::write(self.pin_marker(name), b"")?;
        Ok(())
    }

    pub fn unpin(&self, name: &str) -> Result<()> {
        if !valid_name(name) {
            return Err(Error::BadName(name.to_string()));
        }
        match fs::remove_file(self.pin_marker(name)) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    pub fn is_pinned(&self, name: &str) -> bool {
        valid_name(name) && self.pin_marker(name).is_file()
    }

    /// Delete unpinned files at least `max_age` old relative to `now`. Returns their names.
    pub fn expire(&self, max_age: Duration, now: SystemTime) -> Result<Vec<String>> {
        let mut gone = Vec::new();
        for entry in self.entries()? {
            if entry.pinned {
                continue;
            }
            let age = now.duration_since(entry.ts).unwrap_or_default();
            if age >= max_age {
                fs::remove_file(self.root.join(&entry.name))?;
                gone.push(entry.name);
            }
        }
        if !gone.is_empty() {
            // A deletion can take usage back under the threshold, which re-arms the callback.
            self.observe_threshold()?;
        }
        Ok(gone)
    }
}
