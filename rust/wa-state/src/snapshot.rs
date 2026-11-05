//! Snapshots: a versioned, checksummed, zstd-compressed copy of one namespace - for backup and for
//! moving a component between nodes.
//!
//! # File format v1
//!
//! ```text
//! "WASTATE1"                      8 bytes, so an operator can tell it from any other file
//! zstd frame of the payload       one frame; the payload is what the checksum covers
//!
//! payload =
//!   u32 head_len | head JSON
//!   entry*                          u32 klen | key | u32 vlen | value
//!   footer: "WST1" | u64 entries | u64 bytes | sha256(payload[..footer])
//! ```
//!
//! The header comes first so a reader knows the schema/component before it has read the data; the
//! checksum and the counts come last because a streaming writer does not know them until the end. The
//! checksum covers the **uncompressed** payload, so a corrupted zstd stream and a payload that
//! decompresses to the wrong bytes are both refused by the same test. The header is JSON because the
//! operator's next tool is usually `jq` or an editor; the entries are binary because keys are bytes.
//!
//! The snapshot never carries `__wa/` meta keys. The schema version is in the header; importing sets
//! the meta from the header, so a snapshot cannot be used to forge a schema version or a migration
//! journal.

use crate::batch::Batch;
use crate::kv::Kv;
use crate::meta::{is_reserved, ComponentInfo, Meta};
#[cfg(feature = "snapshot")]
use crate::meta;
use crate::{check_size, Error, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::Write;
#[cfg(feature = "snapshot")]
use std::io::Read;

/// Identifies the file. A component snapshot is not a database file and must not be mistaken for one.
pub const MAGIC: &[u8; 8] = b"WASTATE1";
/// The format this code writes and the only one it reads. Bumped when the *layout* changes; the
/// schema version inside is the component's, and the two move independently.
pub const SNAPSHOT_FORMAT: u32 = 1;
pub(crate) const FOOTER_TAG: &[u8; 4] = b"WST1";
#[cfg(feature = "snapshot")]
const FOOTER_LEN: usize = 4 + 8 + 8 + 32;

/// Default ceiling for a snapshot the library takes or reads into memory (512 MiB). A namespace
/// above it is a case for a paged export/import, not for one allocation.
pub const DEFAULT_MAX_BYTES: u64 = 512 << 20;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
struct Head {
    format: u32,
    schema_version: u32,
    component: String,
    component_version: String,
    component_sha256: String,
    created_at_ms: u64,
}

/// What a reader learns about a snapshot without touching a namespace.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SnapshotHeader {
    pub format: u32,
    pub schema_version: u32,
    pub component: String,
    pub component_version: String,
    /// The pin recorded as `last_migrated_by` in the source namespace: which build last wrote it.
    pub component_sha256: String,
    pub created_at_ms: u64,
    pub entries: u64,
    pub bytes: u64,
    /// Lowercase hex sha256 of the uncompressed payload.
    pub sha256: String,
}

/// A snapshot held in memory: taken by the migrator before it writes, or read by a caller that wants
/// to inspect before importing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub header: SnapshotHeader,
    pub entries: Vec<(Vec<u8>, Vec<u8>)>,
}

/// Export bounds. The defaults are the policy; a caller only sets them to tighten it.
#[derive(Clone, Debug)]
pub struct ExportOptions {
    /// zstd level. 3 is the default and is what the host should use: snapshots are cold data, and a
    /// slower level mostly costs the writer's CPU, not disk.
    pub level: i32,
    /// Entries per `scan_page`. Bounds the memory export needs beyond the store's own page size.
    pub page: usize,
    /// Refuse to write a snapshot larger than this (keys + values), so an export of a runaway
    /// namespace does not fill a disk.
    pub max_bytes: u64,
}

impl Default for ExportOptions {
    fn default() -> Self {
        Self {
            level: 3,
            page: 512,
            max_bytes: DEFAULT_MAX_BYTES,
        }
    }
}

/// Import policy. It is explicit because both defaults that look convenient are unsafe: replacing a
/// live namespace, and accepting whatever version a file happens to carry.
#[derive(Clone, Debug)]
pub struct ImportOptions {
    /// Require this component id. A node move names the component the namespace belongs to, so a
    /// snapshot of some other component can never become "this" component's history.
    pub expect_component: Option<String>,
    /// Replace the namespace's current keys. Off by default.
    pub replace: bool,
    /// Require this schema version. The host passes the version the installed component writes.
    pub expect_version: Option<u32>,
    /// Require this provenance pin (the `component_sha256` of the header).
    pub expect_sha256: Option<String>,
    /// Ceiling for the decompressed payload; also the memory a corrupt file may cost.
    pub max_bytes: u64,
}

impl Default for ImportOptions {
    fn default() -> Self {
        Self {
            expect_component: None,
            replace: false,
            expect_version: None,
            expect_sha256: None,
            max_bytes: DEFAULT_MAX_BYTES,
        }
    }
}

impl Snapshot {
    /// Read the whole namespace into a snapshot, hashing as it goes.
    ///
    /// `meta` supplies the identity: a snapshot says "this data was last written by that component at
    /// that schema version", and the header repeats it so a node that has never seen the component can
    /// still decide whether it can use the data.
    pub fn take(kv: &mut dyn Kv, meta: &Meta, now_ms: u64, max_bytes: u64) -> Result<Self> {
        let head = Head::new(
            meta.schema_version,
            &meta.component,
            &meta.component_version,
            &meta.last_migrated_by,
            now_ms,
        )?;
        let mut sink = std::io::sink();
        let mut payload = Payload::begin(&mut sink, &head)?;
        let mut entries = Vec::new();
        let mut cursor: Option<Vec<u8>> = None;
        loop {
            let page = kv.scan_page(b"", cursor.as_deref(), 512)?;
            if page.is_empty() {
                break;
            }
            for (key, value) in page.iter() {
                if is_reserved(key) {
                    continue;
                }
                payload.entry(&mut sink, key, value, max_bytes)?;
                entries.push((key.clone(), value.clone()));
            }
            cursor = page.last().map(|(key, _)| key.clone());
        }
        let (count, bytes, digest) = payload.finish(&mut sink)?;
        Ok(Snapshot {
            header: SnapshotHeader {
                format: SNAPSHOT_FORMAT,
                schema_version: head.schema_version,
                component: head.component,
                component_version: head.component_version,
                component_sha256: head.component_sha256,
                created_at_ms: head.created_at_ms,
                entries: count,
                bytes,
                sha256: hex(&digest),
            },
            entries,
        })
    }

    /// The snapshot as a migration batch. Reserved keys cannot appear (they are filtered on take and
    /// refused on read), so a step cannot see them through a snapshot either.
    pub fn batch(&self) -> Result<Batch> {
        Batch::from_entries(self.entries.iter().map(|(key, value)| (key.clone(), value.clone())))
    }

    #[cfg(feature = "snapshot")]
    pub fn to_vec(&self, level: i32) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        self.write(&mut out, level)?;
        Ok(out)
    }

    #[cfg(feature = "snapshot")]
    pub fn write(&self, out: &mut dyn Write, level: i32) -> Result<()> {
        // The header describes the entries; if a caller assembled a Snapshot by hand and got that
        // wrong, the file would be internally consistent but lie about its contents. Refuse instead.
        self.check_header()?;
        let head = Head::from_header(&self.header)?;
        out.write_all(MAGIC)?;
        let mut encoder = zstd::stream::write::Encoder::new(out, level)
            .map_err(|error| Error::Kv(format!("zstd encoder: {error}")))?;
        let mut payload = Payload::begin(&mut encoder, &head)?;
        for (key, value) in &self.entries {
            payload.entry(&mut encoder, key, value, DEFAULT_MAX_BYTES)?;
        }
        payload.finish(&mut encoder)?;
        encoder
            .finish()
            .map_err(|error| Error::Kv(format!("zstd finish: {error}")))?;
        Ok(())
    }

    #[cfg(feature = "snapshot")]
    fn check_header(&self) -> Result<()> {
        Head::from_header(&self.header)?;
        let mut sink = std::io::sink();
        let mut payload = Payload::begin(&mut sink, &Head::from_header(&self.header)?)?;
        for (key, value) in &self.entries {
            payload.entry(&mut sink, key, value, DEFAULT_MAX_BYTES)?;
        }
        let (count, bytes, digest) = payload.finish(&mut sink)?;
        if count != self.header.entries
            || bytes != self.header.bytes
            || hex(&digest) != self.header.sha256
        {
            return Err(Error::Corrupt(
                "snapshot header does not describe its entries".into(),
            ));
        }
        Ok(())
    }
}

impl Head {
    fn new(
        schema_version: u32,
        component: &str,
        component_version: &str,
        component_sha256: &str,
        created_at_ms: u64,
    ) -> Result<Self> {
        if schema_version == 0 {
            return Err(Error::Corrupt("schema versions start at 1".into()));
        }
        ComponentInfo::new(component, component_version, component_sha256)?;
        Ok(Head {
            format: SNAPSHOT_FORMAT,
            schema_version,
            component: component.to_owned(),
            component_version: component_version.to_owned(),
            component_sha256: component_sha256.to_owned(),
            created_at_ms,
        })
    }

    #[cfg(feature = "snapshot")]
    fn from_header(header: &SnapshotHeader) -> Result<Self> {
        if header.format != SNAPSHOT_FORMAT {
            return Err(Error::Format(format!(
                "snapshot format {} is not supported by this build (v{SNAPSHOT_FORMAT})",
                header.format
            )));
        }
        Head::new(
            header.schema_version,
            &header.component,
            &header.component_version,
            &header.component_sha256,
            header.created_at_ms,
        )
    }
}

/// The incremental payload writer: hashes everything it writes and keeps the counts the footer needs.
/// Both the streaming [`export`] and the in-memory [`Snapshot::take`] go through it, so the bytes on
/// disk and the bytes a test compares cannot drift apart.
struct Payload {
    hasher: Sha256,
    entries: u64,
    bytes: u64,
}

impl Payload {
    fn begin(out: &mut dyn Write, head: &Head) -> Result<Self> {
        let json = serde_json::to_vec(head)
            .map_err(|error| Error::Kv(format!("snapshot header encode: {error}")))?;
        let mut hasher = Sha256::new();
        write_hashed(out, &mut hasher, &(json.len() as u32).to_le_bytes())?;
        write_hashed(out, &mut hasher, &json)?;
        Ok(Payload {
            hasher,
            entries: 0,
            bytes: 0,
        })
    }

    fn entry(
        &mut self,
        out: &mut dyn Write,
        key: &[u8],
        value: &[u8],
        max_bytes: u64,
    ) -> Result<()> {
        if is_reserved(key) {
            return Err(Error::Corrupt(
                "a snapshot entry addresses a reserved meta key".into(),
            ));
        }
        check_size(key, Some(value))?;
        let added = key.len() as u64 + value.len() as u64;
        if self.bytes.saturating_add(added) > max_bytes {
            return Err(Error::Limit {
                what: "snapshot",
                limit: max_bytes,
                found: self.bytes + added,
            });
        }
        self.entries += 1;
        self.bytes += added;
        write_hashed(out, &mut self.hasher, &(key.len() as u32).to_le_bytes())?;
        write_hashed(out, &mut self.hasher, key)?;
        write_hashed(out, &mut self.hasher, &(value.len() as u32).to_le_bytes())?;
        write_hashed(out, &mut self.hasher, value)?;
        Ok(())
    }

    /// Write the footer and return the counts and digest that describe the payload.
    fn finish(mut self, out: &mut dyn Write) -> Result<(u64, u64, [u8; 32])> {
        let digest: [u8; 32] = self.hasher.finalize_reset().into();
        out.write_all(FOOTER_TAG)?;
        out.write_all(&self.entries.to_le_bytes())?;
        out.write_all(&self.bytes.to_le_bytes())?;
        out.write_all(&digest)?;
        Ok((self.entries, self.bytes, digest))
    }
}

fn write_hashed(out: &mut dyn Write, hasher: &mut Sha256, bytes: &[u8]) -> Result<()> {
    hasher.update(bytes);
    out.write_all(bytes)?;
    Ok(())
}

/// Stream every key of `kv` into `out` - one pass, no whole-namespace copy. This is the backup and
/// node-move path; the migrator uses [`Snapshot::take`] because it needs the bytes in hand.
#[cfg(feature = "snapshot")]
pub fn export(
    kv: &mut dyn Kv,
    meta: &Meta,
    out: &mut dyn Write,
    now_ms: u64,
    options: &ExportOptions,
) -> Result<SnapshotHeader> {
    let head = Head::new(
        meta.schema_version,
        &meta.component,
        &meta.component_version,
        &meta.last_migrated_by,
        now_ms,
    )?;
    out.write_all(MAGIC)?;
    let mut encoder = zstd::stream::write::Encoder::new(out, options.level)
        .map_err(|error| Error::Kv(format!("zstd encoder: {error}")))?;
    let mut payload = Payload::begin(&mut encoder, &head)?;
    let mut cursor: Option<Vec<u8>> = None;
    loop {
        let page = kv.scan_page(b"", cursor.as_deref(), options.page.max(1))?;
        if page.is_empty() {
            break;
        }
        for (key, value) in page.iter() {
            if is_reserved(key) {
                continue;
            }
            payload.entry(&mut encoder, key, value, options.max_bytes)?;
        }
        cursor = page.last().map(|(key, _)| key.clone());
    }
    let (entries, bytes, digest) = payload.finish(&mut encoder)?;
    encoder
        .finish()
        .map_err(|error| Error::Kv(format!("zstd finish: {error}")))?;
    Ok(SnapshotHeader {
        format: SNAPSHOT_FORMAT,
        schema_version: head.schema_version,
        component: head.component,
        component_version: head.component_version,
        component_sha256: head.component_sha256,
        created_at_ms: head.created_at_ms,
        entries,
        bytes,
        sha256: hex(&digest),
    })
}

/// Check a snapshot without writing anything: magic, format, checksum, counts, key sizes, and that
/// no reserved key is smuggled in. Everything [`import`] trusts, before it touches a namespace.
#[cfg(feature = "snapshot")]
pub fn verify(input: &mut dyn Read, options: &ImportOptions) -> Result<SnapshotHeader> {
    Ok(read_snapshot(input, options.max_bytes)?.header)
}

/// Import a verified snapshot into an empty namespace (or, with `replace`, over the current data).
///
/// Not transactional: the store underneath the trait has no multi-key transaction, so a kv failure
/// part-way leaves a partial namespace. That is visible (the error is returned), the source snapshot
/// is untouched, and `replace: true` is the repair. The alternative - a second journal for imports -
/// is noted in REPORT.md rather than half-built.
#[cfg(feature = "snapshot")]
pub fn import(
    kv: &mut dyn Kv,
    input: &mut dyn Read,
    now_ms: u64,
    options: &ImportOptions,
) -> Result<SnapshotHeader> {
    let ReadSnapshot { head, entries, header } = read_snapshot(input, options.max_bytes)?;
    if let Some(expected) = &options.expect_component {
        if &header.component != expected {
            return Err(Error::OwnerMismatch {
                expected: expected.clone(),
                found: header.component.clone(),
            });
        }
    }
    if let Some(expected) = options.expect_version {
        if header.schema_version != expected {
            return Err(Error::SchemaVersionMismatch {
                expected,
                found: header.schema_version,
            });
        }
    }
    if let Some(expected) = &options.expect_sha256 {
        if &header.component_sha256 != expected {
            return Err(Error::ComponentMismatch {
                expected: expected.clone(),
                found: header.component_sha256.clone(),
            });
        }
    }
    let existing = meta::user_keys(kv)?;
    if !existing.is_empty() {
        if !options.replace {
            return Err(Error::NotEmpty {
                keys: existing.len(),
            });
        }
        for key in &existing {
            kv.del(key)?;
        }
        // A replaced namespace starts over: an unfinished migration of the data that was just
        // deleted is not work on the data that replaced it.
        kv.del(meta::key::JOURNAL)?;
        kv.del(meta::key::PENDING)?;
    }
    for (key, value) in &entries {
        kv.put(key, value)?;
    }
    let target = Meta {
        schema_version: head.schema_version,
        component: head.component.clone(),
        component_version: head.component_version.clone(),
        last_migrated_by: head.component_sha256.clone(),
        created_at_ms: head.created_at_ms,
        last_migrated_at_ms: now_ms,
    };
    target.write(kv, now_ms)?;
    Ok(header)
}

/// A snapshot that passed every check: the decoded header, its entries, and the published header.
#[cfg(feature = "snapshot")]
struct ReadSnapshot {
    head: Head,
    entries: Vec<(Vec<u8>, Vec<u8>)>,
    header: SnapshotHeader,
}

/// Read and verify a snapshot. Nothing is written to a namespace here, so `verify` and `import`
/// cannot disagree about what a valid file is.
#[cfg(feature = "snapshot")]
fn read_snapshot(input: &mut dyn Read, max_bytes: u64) -> Result<ReadSnapshot> {
    let mut magic = [0u8; 8];
    input
        .read_exact(&mut magic)
        .map_err(|error| Error::Format(format!("snapshot header: {error}")))?;
    if &magic != MAGIC {
        return Err(Error::Format(
            "not a wasm-agent state snapshot (bad magic)".into(),
        ));
    }
    let decoder = zstd::stream::read::Decoder::new(input)
        .map_err(|error| Error::Format(format!("zstd: {error}")))?;
    let mut payload = Vec::new();
    decoder
        .take(max_bytes.saturating_add(1))
        .read_to_end(&mut payload)
        .map_err(|error| Error::Format(format!("snapshot body: {error}")))?;
    if payload.len() as u64 > max_bytes {
        return Err(Error::Limit {
            what: "snapshot payload",
            limit: max_bytes,
            found: payload.len() as u64,
        });
    }

    let foot_start = payload
        .len()
        .checked_sub(FOOTER_LEN)
        .ok_or_else(|| Error::Format("snapshot is too short for its footer".into()))?;
    let head_len = u32::from_le_bytes(
        payload
            .get(0..4)
            .ok_or_else(|| Error::Format("snapshot has no header length".into()))?
            .try_into()
            .expect("4 bytes"),
    ) as usize;
    let head_end = 4usize
        .checked_add(head_len)
        .filter(|end| *end <= foot_start)
        .ok_or_else(|| Error::Format("snapshot header length runs past the payload".into()))?;
    let head: Head = serde_json::from_slice(&payload[4..head_end])
        .map_err(|error| Error::Format(format!("snapshot header does not parse: {error}")))?;
    if head.format != SNAPSHOT_FORMAT {
        return Err(Error::Format(format!(
            "snapshot format {} is not supported by this build (v{SNAPSHOT_FORMAT})",
            head.format
        )));
    }
    // Validate the identity here: an import writes it into meta, and a malformed id would make the
    // namespace unopenable for the very component the file came from.
    ComponentInfo::new(
        head.component.clone(),
        head.component_version.clone(),
        head.component_sha256.clone(),
    )?;
    if head.schema_version == 0 {
        return Err(Error::Format("snapshot schema version is 0".into()));
    }

    let mut entries = Vec::new();
    let mut bytes = 0u64;
    let mut at = head_end;
    while at < foot_start {
        let key_len = stream_length(&payload, &mut at, foot_start)?;
        let key = stream_take(&payload, &mut at, key_len, foot_start)?.to_vec();
        let value_len = stream_length(&payload, &mut at, foot_start)?;
        let value = stream_take(&payload, &mut at, value_len, foot_start)?.to_vec();
        if is_reserved(&key) {
            return Err(Error::Corrupt(
                "snapshot carries a reserved meta key".into(),
            ));
        }
        check_size(&key, Some(&value))?;
        bytes += key.len() as u64 + value.len() as u64;
        entries.push((key, value));
    }
    if at != foot_start {
        return Err(Error::Format(
            "snapshot entries do not end at the footer".into(),
        ));
    }
    if &payload[foot_start..foot_start + 4] != FOOTER_TAG {
        return Err(Error::Format("snapshot has no footer".into()));
    }
    let footer_entries = u64::from_le_bytes(
        payload[foot_start + 4..foot_start + 12]
            .try_into()
            .expect("8 bytes"),
    );
    let footer_bytes = u64::from_le_bytes(
        payload[foot_start + 12..foot_start + 20]
            .try_into()
            .expect("8 bytes"),
    );
    let recorded: [u8; 32] = payload[foot_start + 20..foot_start + 52]
        .try_into()
        .expect("32 bytes");
    let computed: [u8; 32] = Sha256::digest(&payload[..foot_start]).into();
    if computed != recorded {
        return Err(Error::ChecksumMismatch {
            expected: hex(&recorded),
            found: hex(&computed),
        });
    }
    if footer_entries != entries.len() as u64 || footer_bytes != bytes {
        return Err(Error::Format(
            "snapshot footer counts do not match its entries".into(),
        ));
    }
    let header = SnapshotHeader {
        format: head.format,
        schema_version: head.schema_version,
        component: head.component.clone(),
        component_version: head.component_version.clone(),
        component_sha256: head.component_sha256.clone(),
        created_at_ms: head.created_at_ms,
        entries: footer_entries,
        bytes: footer_bytes,
        sha256: hex(&recorded),
    };
    Ok(ReadSnapshot {
        head,
        entries,
        header,
    })
}

#[cfg(feature = "snapshot")]
fn stream_take<'a>(
    payload: &'a [u8],
    at: &mut usize,
    len: usize,
    end: usize,
) -> Result<&'a [u8]> {
    let stop = at
        .checked_add(len)
        .filter(|stop| *stop <= end)
        .ok_or_else(|| Error::Format("snapshot entry is truncated".into()))?;
    let slice = &payload[*at..stop];
    *at = stop;
    Ok(slice)
}

#[cfg(feature = "snapshot")]
fn stream_length(payload: &[u8], at: &mut usize, end: usize) -> Result<usize> {
    Ok(u32::from_le_bytes(
        stream_take(payload, at, 4, end)?.try_into().expect("4 bytes"),
    ) as usize)
}

fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}
