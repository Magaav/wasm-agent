//! Audit: one append-only record per sensitive call (and per refusal), written through a trait.
//!
//! A record never carries the target itself unless the operator asks for it
//! ([`TargetMode::Exact`]): by default the target is replaced by `sha256:<32 hex>`, which is enough
//! to prove "the same chat was used twice" without storing a phone number, a secret name or a kv
//! key in a file that outlives the policy. Payload arguments are never passed to this module, so
//! message text cannot reach the audit trail by construction.
//!
//! Two sinks ship here: [`MemoryAudit`] (bounded ring for tests and for `wa` to expose over
//! `host.components()`) and [`FileAudit`] (JSONL, flushed per record, rotated by size, one backup
//! generation). A sink failure is returned to the caller; it is never swallowed.
use crate::Decision;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::fmt;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

/// How a record names its target.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum TargetMode {
    /// `sha256:` + the first 16 bytes of the digest, hex (32 chars). Stable, not reversible.
    #[default]
    Digest,
    /// The constant `<redacted>`.
    Redacted,
    /// The target verbatim, capped at [`MAX_FIELD`]. Only for ids the operator already keeps in a
    /// readable policy file (an allowlisted chat id, a capability name), never for secrets.
    Exact,
}

/// Longest component, capability and target field kept in a record; longer values are cut and
/// marked, so one record cannot grow without bound.
pub const MAX_FIELD: usize = 160;

/// `allow` / `deny` / `rate_limited` / `needs_approval`, as written in the record.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DecisionCode {
    Allow,
    Deny,
    RateLimited,
    NeedsApproval,
}

impl DecisionCode {
    pub fn as_str(&self) -> &'static str {
        match self {
            DecisionCode::Allow => "allow",
            DecisionCode::Deny => "deny",
            DecisionCode::RateLimited => "rate_limited",
            DecisionCode::NeedsApproval => "needs_approval",
        }
    }
}

impl fmt::Display for DecisionCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One audited decision. Field names are the schema; `schema` bumps when the shape changes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AuditRecord {
    /// Schema of this record (1).
    pub schema: u32,
    /// Injected clock: epoch milliseconds.
    pub ts_ms: u64,
    pub component: String,
    pub capability: String,
    /// `sha256:<32 hex>`, `<redacted>` or the target verbatim (see [`TargetMode`]); `-` when the
    /// call has no target.
    pub target: String,
    pub decision: DecisionCode,
    /// Why: the same snake_case reason the caller got back, e.g. `target_not_allowed`.
    pub reason: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_after_ms: Option<u64>,
}

/// Record schema version.
pub const RECORD_SCHEMA: u32 = 1;

impl AuditRecord {
    /// Build a record for `decision`. `policy_target` is the raw target (never logged directly).
    pub fn new(
        ts_ms: u64,
        component: &str,
        capability: &str,
        target: Option<&str>,
        decision: &Decision,
        mode: TargetMode,
    ) -> AuditRecord {
        AuditRecord {
            schema: RECORD_SCHEMA,
            ts_ms,
            component: field(component),
            capability: field(capability),
            target: match target {
                Some(t) => render_target(mode, t),
                None => "-".to_string(),
            },
            decision: decision.code(),
            reason: decision.reason_str().to_string(),
            retry_after_ms: match decision {
                Decision::RateLimited { retry_after_ms, .. } => Some(*retry_after_ms),
                _ => None,
            },
        }
    }

    /// One line of JSON, no trailing newline (every field is JSON-escaped, so no raw newline can
    /// reach the file).
    pub fn to_json_line(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| {
            // Cannot happen for these field types; still never emit a half record.
            format!(
                "{{\"schema\":{RECORD_SCHEMA},\"ts_ms\":{},\"decision\":\"deny\",\"reason\":\"unserializable\"}}",
                self.ts_ms
            )
        })
    }
}

/// Render a target for the audit trail (see [`TargetMode`]).
pub fn render_target(mode: TargetMode, target: &str) -> String {
    match mode {
        TargetMode::Digest => format!("sha256:{}", digest_hex(target)),
        TargetMode::Redacted => "<redacted>".to_string(),
        TargetMode::Exact => field(target),
    }
}

/// First 16 bytes of SHA-256, hex: 32 characters, stable across runs and nodes.
pub fn digest_hex(target: &str) -> String {
    let digest = Sha256::digest(target.as_bytes());
    let mut out = String::with_capacity(32);
    for byte in &digest[..16] {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

fn field(value: &str) -> String {
    let mut cut: String = value.chars().take(MAX_FIELD).collect();
    if value.chars().count() > MAX_FIELD {
        cut.push('…');
    }
    cut
}

/// Why a sink refused a record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditError {
    /// Which sink refused (`file`, `memory`, …).
    pub sink: &'static str,
    /// What went wrong; an `io::Error` message, never a target or a secret.
    pub detail: String,
}

impl fmt::Display for AuditError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "audit write failed in sink {}: {}", self.sink, self.detail)
    }
}

impl std::error::Error for AuditError {}

/// Where records go. The host owns one sink and passes `&mut` to
/// [`Engine::enforce`](crate::Engine::enforce), so record order equals decision order.
pub trait AuditSink {
    fn write(&mut self, record: &AuditRecord) -> Result<(), AuditError>;
}

/// Bounded in-memory sink for tests and for a "last N decisions" view. When the bound is reached
/// the oldest record is dropped and counted in [`MemoryAudit::dropped`] — visible, not silent.
#[derive(Debug)]
pub struct MemoryAudit {
    records: VecDeque<AuditRecord>,
    limit: usize,
    dropped: u64,
}

impl Default for MemoryAudit {
    fn default() -> Self {
        MemoryAudit::with_limit(10_000)
    }
}

impl MemoryAudit {
    pub fn new() -> MemoryAudit {
        MemoryAudit::default()
    }

    pub fn with_limit(limit: usize) -> MemoryAudit {
        MemoryAudit { records: VecDeque::new(), limit: limit.max(1), dropped: 0 }
    }

    pub fn records(&self) -> impl ExactSizeIterator<Item = &AuditRecord> {
        self.records.iter()
    }

    /// Records as a slice-like vec, newest last.
    pub fn to_vec(&self) -> Vec<AuditRecord> {
        self.records.iter().cloned().collect()
    }

    pub fn len(&self) -> usize {
        self.records.len()
    }

    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    /// How many records were dropped because of the bound.
    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    pub fn clear(&mut self) {
        self.records.clear();
        self.dropped = 0;
    }
}

impl AuditSink for MemoryAudit {
    fn write(&mut self, record: &AuditRecord) -> Result<(), AuditError> {
        if self.records.len() == self.limit {
            self.records.pop_front();
            self.dropped += 1;
        }
        self.records.push_back(record.clone());
        Ok(())
    }
}

/// Append-only JSONL file, flushed after every record, rotated by size.
///
/// Rotation: when the next line would push the file past `max_bytes`, the current file is flushed
/// and renamed to `<path>.1` (replacing an older `.1`), and a fresh file is opened. One backup
/// generation, no unbounded disk growth; the count of rotations is available for the operator.
/// The file is flushed but not `fsync`ed: the audit trail survives a process crash, not a power
/// cut. Rotation is not an archive — a bounded store is described in `docs/GRANT-POLICY.md`.
#[derive(Debug)]
pub struct FileAudit {
    path: PathBuf,
    file: File,
    max_bytes: u64,
    written: u64,
    rotations: u64,
}

impl FileAudit {
    /// Open (create or append) `path`, rotating at `max_bytes`.
    pub fn open(path: impl Into<PathBuf>, max_bytes: u64) -> std::io::Result<FileAudit> {
        let path = path.into();
        let file = open_append(&path)?;
        let written = file.metadata().map(|m| m.len()).unwrap_or(0);
        Ok(FileAudit { path, file, max_bytes: max_bytes.max(1), written, rotations: 0 })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Bytes in the current file.
    pub fn written(&self) -> u64 {
        self.written
    }

    pub fn rotations(&self) -> u64 {
        self.rotations
    }

    fn rotate(&mut self) -> std::io::Result<()> {
        self.file.flush()?;
        let backup = self.path.with_extension(match self.path.extension() {
            Some(ext) => format!("{}.1", ext.to_string_lossy()),
            None => "1".to_string(),
        });
        // Windows will not rename over an existing file; a missing backup is not an error.
        let _ = std::fs::remove_file(&backup);
        std::fs::rename(&self.path, &backup)?;
        self.file = open_append(&self.path)?;
        self.written = 0;
        self.rotations += 1;
        Ok(())
    }
}

fn open_append(path: &Path) -> std::io::Result<File> {
    if let Some(dir) = path.parent() {
        if !dir.as_os_str().is_empty() {
            std::fs::create_dir_all(dir)?;
        }
    }
    OpenOptions::new().create(true).append(true).open(path)
}

impl AuditSink for FileAudit {
    fn write(&mut self, record: &AuditRecord) -> Result<(), AuditError> {
        let mut line = record.to_json_line();
        line.push('\n');
        let bytes = line.as_bytes();
        let fail = |detail: String| AuditError { sink: "file", detail };
        if self.written > 0 && self.written + bytes.len() as u64 > self.max_bytes {
            self.rotate().map_err(|e| fail(format!("rotate: {e}")))?;
        }
        self.file.write_all(bytes).map_err(|e| fail(format!("write: {e}")))?;
        self.file.flush().map_err(|e| fail(format!("flush: {e}")))?;
        self.written += bytes.len() as u64;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Reason;

    fn temp_path(name: &str) -> PathBuf {
        let mut dir = std::env::temp_dir();
        dir.push(format!("wa-grant-policy-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir.push("audit.jsonl");
        dir
    }

    #[test]
    fn records_never_carry_the_raw_target_by_default() {
        let decision = Decision::Deny(Reason::TargetNotAllowed);
        let rec = AuditRecord::new(7, "wa-whatsapp", "whatsapp.send", Some("5511999999999@g.us"), &decision, TargetMode::Digest);
        assert_eq!(rec.target, format!("sha256:{}", digest_hex("5511999999999@g.us")));
        assert_eq!(rec.target.len(), "sha256:".len() + 32);
        assert!(!rec.to_json_line().contains("5511999999999"));
        assert_eq!(rec.decision, DecisionCode::Deny);
        assert_eq!(rec.reason, "target_not_allowed");
        assert_eq!(rec.retry_after_ms, None);

        let redacted = AuditRecord::new(7, "c", "k", Some("s3cret"), &Decision::Allow, TargetMode::Redacted);
        assert_eq!(redacted.target, "<redacted>");
        let exact = AuditRecord::new(7, "c", "k", Some("chat:alerts"), &Decision::Allow, TargetMode::Exact);
        assert_eq!(exact.target, "chat:alerts");
        let none = AuditRecord::new(7, "c", "k", None, &Decision::Allow, TargetMode::Exact);
        assert_eq!(none.target, "-");
    }

    #[test]
    fn digest_is_stable_and_distinguishes_targets() {
        assert_eq!(digest_hex("a"), digest_hex("a"));
        assert_ne!(digest_hex("a"), digest_hex("b"));
        assert_eq!(digest_hex(""), "e3b0c44298fc1c149afbf4c8996fb924");
    }

    #[test]
    fn retry_after_is_recorded_for_rate_limits_and_lines_are_one_line() {
        let decision = Decision::RateLimited { retry_after_ms: 8_571, reason: Reason::TargetRateLimited };
        let rec = AuditRecord::new(1, "c", "k", Some("t"), &decision, TargetMode::Exact);
        assert_eq!(rec.retry_after_ms, Some(8_571));
        let weird = AuditRecord::new(1, "c\nname", "k", Some("t\narget"), &Decision::Allow, TargetMode::Exact);
        let line = weird.to_json_line();
        assert!(!line.contains('\n'));
        assert_eq!(line.matches('\\').count(), 2); // both newlines escaped
    }

    #[test]
    fn long_fields_are_cut_so_a_record_stays_small() {
        let long = "x".repeat(MAX_FIELD * 2);
        let rec = AuditRecord::new(1, &long, &long, Some(&long), &Decision::Allow, TargetMode::Exact);
        assert_eq!(rec.component.chars().count(), MAX_FIELD + 1);
        assert!(rec.component.ends_with('…'));
        assert!(rec.to_json_line().len() < 1_000);
    }

    #[test]
    fn memory_sink_is_bounded_and_counts_what_it_dropped() {
        let mut sink = MemoryAudit::with_limit(2);
        for i in 0..5u64 {
            sink.write(&AuditRecord::new(i, "c", "k", None, &Decision::Allow, TargetMode::Digest)).unwrap();
        }
        assert_eq!(sink.len(), 2);
        assert_eq!(sink.dropped(), 3);
        let ts: Vec<u64> = sink.records().map(|r| r.ts_ms).collect();
        assert_eq!(ts, vec![3, 4]);
    }

    #[test]
    fn file_sink_appends_flushes_and_rotates_by_size() {
        let path = temp_path("file");
        let mut sink = FileAudit::open(&path, 400).unwrap();
        let rec = AuditRecord::new(1, "wa-whatsapp", "whatsapp.send", Some("chat:alerts"), &Decision::Allow, TargetMode::Exact);
        for _ in 0..20 {
            sink.write(&rec).unwrap();
        }
        assert!(sink.rotations() > 0);
        let current = std::fs::read_to_string(&path).unwrap();
        let backup = std::fs::read_to_string(path.with_extension("jsonl.1")).unwrap();
        assert!(current.lines().count() + backup.lines().count() <= 20);
        assert!(current.lines().all(|l| l.starts_with('{')));
        // rotation happened before an over-sized file could exist
        assert!(sink.written() <= 400);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());

        // reopening an existing file appends instead of truncating
        let path2 = temp_path("append");
        {
            let mut first = FileAudit::open(&path2, 10_000).unwrap();
            first.write(&rec).unwrap();
            first.write(&rec).unwrap();
        }
        let mut second = FileAudit::open(&path2, 10_000).unwrap();
        assert_eq!(second.written(), std::fs::metadata(&path2).unwrap().len());
        second.write(&rec).unwrap();
        assert_eq!(std::fs::read_to_string(&path2).unwrap().lines().count(), 3);
        let _ = std::fs::remove_dir_all(path2.parent().unwrap());
    }
}
