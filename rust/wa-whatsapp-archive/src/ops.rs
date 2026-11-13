//! The archive's operations: cut a month out of the index, put it back, push it away, expire it.
//!
//! Every one of them is written to be run again after a crash: a cut that died between the write and
//! the delete leaves the file (a second cut replaces it) and the records (a second cut deletes them);
//! a restore that died part-way is a restore that is run again; an unload is a deletion, and a
//! deletion that runs twice deletes the same keys. None of them prints a message: the answers carry a
//! month, counts and a digest.
use crate::{
    collect, decode, encode, file_name, list_dir_files, mark_restored, month_bounds, month_of_file,
    open_payload, seal_payload, sha256_hex, Kv, Manifest, Memory, Sealer, FORMAT, KEEP_AFTER_MONTH_DAYS, SEAL_NAMESPACE,
};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use wa_whatsapp_index::keys;

/// Which component build and schema the data belongs to, as the installed artifact states it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Build {
    pub component_version: String,
    pub schema: String,
}

/// What one cut did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Cut {
    pub month: String,
    pub chats: u64,
    pub messages: u64,
    pub entries: u64,
    pub bytes: u64,
    pub sha256: String,
    pub path: PathBuf,
    /// False when the month held nothing: no file is written for an empty month.
    pub written: bool,
}

/// What one restore did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Restored {
    pub month: String,
    pub entries: u64,
    pub messages: u64,
    pub sha256: String,
    /// True when the month was already marked as restored here (the rows were written again).
    pub again: bool,
}

/// What one unload did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Unloaded {
    pub month: String,
    pub entries: u64,
    pub messages: u64,
    /// True when the month had a restored mark that was removed.
    pub was_restored: bool,
}

/// One archive in the directory, as `list` reports it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Listed {
    pub month: String,
    pub path: String,
    pub bytes: u64,
    pub chats: u64,
    pub messages: u64,
    pub entries: u64,
    pub sha256: String,
    pub component_version: String,
    pub schema: String,
    pub created_ms: i64,
    /// The instant the archive is deleted (month end + 360 days).
    pub expire_ms: i64,
    /// Loaded back into this node's index right now.
    pub restored: bool,
    /// The archive file is not here (it was pushed away): the rows may still be restored here.
    pub missing: bool,
}

/// What one push did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PushReceipt {
    pub month: String,
    /// A node name or a directory, as the caller named it.
    pub to: String,
    pub bytes: u64,
    pub sha256: String,
    /// The digest the target computed over what it received (equal to `sha256`, or the push failed).
    pub verified: String,
    pub removed_local: bool,
}

/// The mark a restored month leaves in the index, so `list` and a prune pass can see it.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
struct Mark {
    month: String,
    restored_ms: i64,
    entries: u64,
    messages: u64,
    sha256: String,
    component_version: String,
    schema: String,
}

// ---- reading the directory ------------------------------------------------------------------------

/// The files an archive directory holds, by month, in the order of their names (which is month order).
fn archive_files(dir: &Path) -> Vec<(String, PathBuf)> {
    let mut out: Vec<(String, PathBuf)> = list_dir_files(dir)
        .into_iter()
        .filter_map(|name| month_of_file(&name).map(|month| (month, dir.join(name))))
        .collect();
    out.sort();
    out
}

fn read_file(path: &Path) -> Result<Vec<u8>, String> {
    std::fs::read(path).map_err(|error| format!("archive_unreadable: {error}"))
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path.parent().ok_or_else(|| "archive_dir_missing".to_string())?;
    std::fs::create_dir_all(parent).map_err(|error| format!("archive_dir_unwritable: {error}"))?;
    let tmp = path.with_extension("waa.partial");
    {
        use std::io::Write;
        let mut file = std::fs::File::create(&tmp).map_err(|error| format!("archive_unwritable: {error}"))?;
        file.write_all(bytes).map_err(|error| format!("archive_unwritable: {error}"))?;
        // Durable before the caller is told it exists: a cut deletes the index afterwards, and a file
        // that is only in a page cache is not a file.
        file.sync_all().map_err(|error| format!("archive_unwritable: {error}"))?;
    }
    std::fs::rename(&tmp, path).map_err(|error| format!("archive_rename_failed: {error}"))?;
    Ok(())
}

/// Verify one archive file: the framing, its format, and the manifest's digest over the sealed body.
///
/// This is what a push target runs, and it needs no key: it answers "are these the bytes the cut
/// wrote", which is the whole of what "verified on arrival" means here.
pub fn verify_file(path: &Path) -> Result<Manifest, String> {
    let bytes = read_file(path)?;
    verify_bytes(&bytes)
}

fn verify_bytes(bytes: &[u8]) -> Result<Manifest, String> {
    let (manifest, body) = decode(bytes)?;
    let body_bytes = body.len() as u64;
    if body_bytes != manifest.payload_bytes {
        return Err("archive_size_mismatch".to_string());
    }
    if sha256_hex(&body) != manifest.sha256 {
        return Err("archive_checksum_mismatch".to_string());
    }
    Ok(manifest)
}

/// Every archive the directory holds, with the months loaded back into `kv` marked.
pub fn list<S: Kv + ?Sized>(kv: &S, dir: &Path) -> Result<Vec<Listed>, String> {
    let marks = restored_months(kv)?;
    let mut out = Vec::new();
    for (month, path) in archive_files(dir) {
        let manifest = match verify_file(&path) {
            Ok(manifest) => manifest,
            Err(reason) => {
                // A file this node cannot verify is still *reported*: deleting it or hiding it would
                // turn a corrupt archive into an archive that never existed.
                let mut listed = Listed { month: month.clone(), path: path.to_string_lossy().to_string(), missing: false, ..Listed::default() };
                listed.sha256 = format!("unverified:{reason}");
                out.push(listed);
                continue;
            }
        };
        let restored = marks.iter().any(|mark| mark == &month);
        out.push(Listed {
            month: month.clone(),
            path: path.to_string_lossy().to_string(),
            bytes: std::fs::metadata(&path).map(|meta| meta.len()).unwrap_or(manifest.payload_bytes),
            chats: manifest.chats,
            messages: manifest.messages,
            entries: manifest.entries,
            sha256: manifest.sha256.clone(),
            component_version: manifest.component_version.clone(),
            schema: manifest.schema.clone(),
            created_ms: manifest.created_ms,
            expire_ms: manifest.expire_ms(),
            restored,
            missing: false,
        });
    }
    // A month that is restored here but whose file has been pushed away is still a month this node
    // answers from: it is listed, with `missing: true`, instead of disappearing from the list.
    for month in marks {
        if out.iter().any(|listed| listed.month == month) {
            continue;
        }
        let mark = read_mark(kv, &month)?.unwrap_or_default();
        out.push(Listed {
            month: month.clone(),
            path: dir.join(file_name(&month)).to_string_lossy().to_string(),
            bytes: 0,
            chats: 0,
            messages: mark.messages,
            entries: mark.entries,
            sha256: mark.sha256,
            component_version: mark.component_version,
            schema: mark.schema,
            created_ms: mark.restored_ms,
            expire_ms: month_bounds(&month).map(|(_, end)| end + KEEP_AFTER_MONTH_DAYS * 86_400_000).unwrap_or(0),
            restored: true,
            missing: true,
        });
    }
    out.sort_by(|a, b| a.month.cmp(&b.month));
    Ok(out)
}

// ---- the marks -----------------------------------------------------------------------------------

fn read_mark<S: Kv + ?Sized>(kv: &S, month: &str) -> Result<Option<Mark>, String> {
    let Some(raw) = kv.get(keys::archive_mark(month).as_bytes())? else { return Ok(None) };
    Ok(serde_json::from_slice::<Mark>(&raw).ok())
}

/// The months loaded into the index here, oldest first.
pub fn restored_months<S: Kv + ?Sized>(kv: &S) -> Result<Vec<String>, String> {
    let prefix = keys::archive_prefix();
    let mut out: Vec<String> = Vec::new();
    let mut cursor: Option<Vec<u8>> = None;
    loop {
        let page = kv.scan(prefix.as_bytes(), cursor.clone(), crate::PAGE)?;
        if page.is_empty() {
            break;
        }
        cursor = page.last().map(|(key, _)| key.clone());
        let short = page.len() < crate::PAGE;
        for (key, _) in page {
            let text = String::from_utf8_lossy(&key).into_owned();
            if let Some(month) = text.strip_prefix(&prefix) {
                out.push(month.to_string());
            }
        }
        if short {
            break;
        }
    }
    out.sort();
    Ok(out)
}

// ---- the month that is due -----------------------------------------------------------------------

/// The oldest month the index holds that is entirely outside the window, if there is one.
///
/// "Entirely outside" is the operator's rule: the live index keeps `keep_days`; a month is cut when its
/// *last* instant is older than that. The answer is the OLDEST such month, so a node that has been off
/// for a year cuts its months one at a time, oldest first, instead of one enormous file.
pub fn due<S: Kv + ?Sized>(kv: &S, now_ms: i64, keep_days: u32) -> Result<Option<String>, String> {
    let Some((oldest_ts, _)) = oldest_age_key(kv)? else { return Ok(None) };
    let month = crate::month_of(oldest_ts);
    let (_, end) = month_bounds(&month)?;
    let window_start = now_ms - i64::from(keep_days) * 86_400_000;
    if end <= window_start {
        Ok(Some(month))
    } else {
        Ok(None)
    }
}

/// Is `month` entirely outside the window `keep_days` wide at `now_ms`?
///
/// The rule a cut obeys, whether the month was chosen by the node or named by an operator: the live
/// index keeps its window and the archive only takes what has left it.
pub fn is_due(month: &str, now_ms: i64, keep_days: u32) -> Result<bool, String> {
    let (_, end) = month_bounds(month)?;
    Ok(end <= now_ms - i64::from(keep_days) * 86_400_000)
}

fn oldest_age_key<S: Kv + ?Sized>(kv: &S) -> Result<Option<(i64, String)>, String> {
    let prefix = format!("{}all/", keys::PREFIX);
    let page = kv.scan(prefix.as_bytes(), None, 1)?;
    let Some((key, _)) = page.into_iter().next() else { return Ok(None) };
    let text = String::from_utf8_lossy(&key).into_owned();
    let rest = text.strip_prefix(&prefix).unwrap_or_default().to_string();
    Ok(keys::from_age(rest.split('/').next().unwrap_or_default()).map(|ts| (ts, rest)))
}

// ---- cut -----------------------------------------------------------------------------------------

/// Cut one month out of the index into its archive file, then remove it from the index.
///
/// Order matters and is the whole of the crash story: the file is written, synced, re-read and verified
/// against its own manifest, and only then are the index's keys deleted. A crash before the delete
/// leaves a month in both places (the next cut replaces the file and deletes the keys); a crash after
/// it leaves nothing to redo.
pub fn cut<S: Kv + ?Sized>(kv: &S, sealer: &dyn Sealer, dir: &Path, month: &str, now_ms: i64, build: &Build) -> Result<Cut, String> {
    let (start, end) = month_bounds(month)?;
    let collected = collect(kv, month)?;
    let mut answer = Cut { month: month.to_string(), chats: collected.chats, messages: collected.messages, ..Cut::default() };
    if collected.is_empty() {
        return Ok(answer);
    }
    let body = seal_payload(sealer, month, &collected.entries)?;
    let manifest = Manifest {
        format: FORMAT,
        month: month.to_string(),
        chats: collected.chats,
        messages: collected.messages,
        entries: collected.entries.len() as u64,
        component_version: build.component_version.clone(),
        schema: build.schema.clone(),
        compression: "zstd".to_string(),
        seal: "xchacha20poly1305".to_string(),
        key_namespace: SEAL_NAMESPACE.to_string(),
        payload_bytes: body.len() as u64,
        sha256: sha256_hex(&body),
        created_ms: now_ms,
        month_start_ms: start,
        month_end_ms: end,
    };
    let bytes = encode(&manifest, &body);
    let path = dir.join(file_name(month));
    write_atomic(&path, &bytes)?;
    // Read back what is on the disk, not what was in the buffer: a truncated write must stop the cut
    // before it deletes the only other copy of the month.
    let verified = verify_file(&path)?;
    if verified.sha256 != manifest.sha256 || verified.entries != manifest.entries {
        return Err("archive_write_unverified".to_string());
    }
    // Delete the pointers first and the age key last, the order `prune` uses: a crash between them
    // leaves an age key whose record is gone (which the next cut and `repair` both tolerate), never a
    // record the age walk can no longer reach.
    let mut age_keys: Vec<Vec<u8>> = Vec::new();
    let mut declared = 0u64;
    for (key, _) in &collected.entries {
        if key.starts_with(format!("{}all/", keys::PREFIX).as_bytes()) {
            age_keys.push(key.clone());
            continue;
        }
        kv.del(key)?;
        declared += 1;
    }
    for key in &age_keys {
        kv.del(key)?;
        declared += 1;
    }
    answer.entries = collected.entries.len() as u64;
    answer.bytes = bytes.len() as u64;
    answer.sha256 = manifest.sha256;
    answer.path = path;
    answer.written = true;
    let _ = declared;
    Ok(answer)
}

// ---- restore and unload ---------------------------------------------------------------------------

/// Load one archived month back into the index, read-only and marked.
///
/// The rows written are the rows the cut wrote (`docs/WHATSAPP-ARCHIVE.md`), with the record marked
/// `restored: true` so retention keeps it, an answer built from it says where it came from, and
/// [`unload`] can take it away again.
pub fn restore<S: Kv + ?Sized>(kv: &S, sealer: &dyn Sealer, dir: &Path, month: &str, now_ms: i64) -> Result<Restored, String> {
    month_bounds(month)?;
    let path = dir.join(file_name(month));
    let manifest = verify_file(&path)?;
    if manifest.month != month {
        return Err("archive_month_mismatch".to_string());
    }
    let body = decode(&read_file(&path)?)?.1;
    let entries = open_payload(sealer, month, &body)?;
    let mut answer = Restored { month: month.to_string(), sha256: manifest.sha256.clone(), ..Restored::default() };
    answer.again = read_mark(kv, month)?.is_some();
    let record_prefix = format!("{}m/", keys::PREFIX);
    let mut at = 0usize;
    for (key, value) in &entries {
        let value = if key.starts_with(record_prefix.as_bytes()) { mark_restored(value) } else { value.clone() };
        kv.set(key, &value)?;
        at += 1;
        if key.starts_with(record_prefix.as_bytes()) {
            answer.messages += 1;
        }
    }
    answer.entries = at as u64;
    let mark = Mark {
        month: month.to_string(),
        restored_ms: now_ms,
        entries: answer.entries,
        messages: answer.messages,
        sha256: manifest.sha256.clone(),
        component_version: manifest.component_version.clone(),
        schema: manifest.schema.clone(),
    };
    kv.set(keys::archive_mark(month).as_bytes(), &serde_json::to_vec(&mark).map_err(|error| format!("archive_mark_encode: {error}"))?)?;
    Ok(answer)
}

/// Take a restored month back out of the index. The archive file is not touched.
///
/// The rows are found the way the cut found them (the month's range in the age index), so an unload
/// still works after the file has been pushed to another node and deleted here.
pub fn unload<S: Kv + ?Sized>(kv: &S, month: &str, _dir: &Path) -> Result<Unloaded, String> {
    let collected = collect(kv, month)?;
    let was_restored = read_mark(kv, month)?.is_some();
    let mut entries = 0u64;
    for (key, _) in &collected.entries {
        kv.del(key)?;
        entries += 1;
    }
    kv.del(keys::archive_mark(month).as_bytes())?;
    Ok(Unloaded { month: month.to_string(), entries, messages: collected.messages, was_restored })
}

// ---- expiry ---------------------------------------------------------------------------------------

/// Delete every archive that is past its 360 days, and unload its rows first.
///
/// A day is measured from the message date, not from the cut: an archive of 2025-03 is deleted 360 days
/// after 2025-03-31, whatever day the node got round to cutting it. The rows go first: an archive whose
/// file is deleted while its month is still loaded would leave rows in the index that no file can
/// explain and that retention is told to keep.
pub fn expire<S: Kv + ?Sized>(kv: &S, dir: &Path, now_ms: i64) -> Result<Vec<String>, String> {
    let mut expired_months = Vec::new();
    let mut candidates: Vec<String> = archive_files(dir).into_iter().map(|(month, _)| month).collect();
    for month in restored_months(kv)? {
        if !candidates.iter().any(|seen| seen == &month) {
            candidates.push(month);
        }
    }
    candidates.sort();
    for month in candidates {
        if !crate::expired(&month, now_ms) {
            continue;
        }
        let _ = unload(kv, &month, dir)?;
        let path = dir.join(file_name(&month));
        if path.exists() {
            std::fs::remove_file(&path).map_err(|error| format!("archive_delete_failed: {error}"))?;
        }
        expired_months.push(month);
    }
    Ok(expired_months)
}

// ---- push -----------------------------------------------------------------------------------------

/// Most bytes one mesh call carries. A month is a few megabytes; a chunk this size keeps one call
/// inside the mesh's own bounds and makes a retry cost one chunk, not the file.
pub const PUSH_CHUNK: usize = 96 * 1024;

/// Push one archive to another disk (or another directory), verify it on arrival and remove the local
/// copy.
///
/// The verification is over the bytes that are actually on the target, re-read there: `sha256` of the
/// sealed body is in the manifest, so the target needs no key to prove it holds what was cut.
pub fn push_to_dir(dir: &Path, month: &str, dest: &Path, keep_local: bool) -> Result<PushReceipt, String> {
    month_bounds(month)?;
    let path = dir.join(file_name(month));
    let bytes = read_file(&path)?;
    let manifest = verify_bytes(&bytes)?;
    std::fs::create_dir_all(dest).map_err(|error| format!("archive_dest_unwritable: {error}"))?;
    let target = dest.join(file_name(month));
    // Same directory as the source is not a push.
    if target == path {
        return Err("archive_push_to_self".to_string());
    }
    write_atomic(&target, &bytes)?;
    let arrived = verify_file(&target)?;
    if arrived.sha256 != manifest.sha256 {
        return Err("archive_push_unverified".to_string());
    }
    let mut removed_local = false;
    if !keep_local {
        std::fs::remove_file(&path).map_err(|error| format!("archive_delete_failed: {error}"))?;
        removed_local = true;
    }
    Ok(PushReceipt {
        month: month.to_string(),
        to: dest.to_string_lossy().to_string(),
        bytes: bytes.len() as u64,
        sha256: manifest.sha256.clone(),
        verified: arrived.sha256,
        removed_local,
    })
}

/// Push one archive to another node over the mesh.
///
/// The file travels in chunks (`PUSH_CHUNK`), and the *target* answers the digest it computed over
/// everything it received; the local copy is removed only when that digest is the manifest's. A target
/// that answers nothing, or answers a different digest, leaves the local archive where it is - a push
/// that cannot be verified is not a push that frees the disk.
pub fn push_to_node(
    dir: &Path,
    month: &str,
    node: &str,
    keep_local: bool,
    send: &mut dyn FnMut(&str, u32, u32, &[u8]) -> Result<String, String>,
) -> Result<PushReceipt, String> {
    month_bounds(month)?;
    let path = dir.join(file_name(month));
    let bytes = read_file(&path)?;
    let manifest = verify_bytes(&bytes)?;
    let chunks: Vec<&[u8]> = if bytes.is_empty() {
        vec![&bytes[..]]
    } else {
        bytes.chunks(PUSH_CHUNK).collect()
    };
    let parts = chunks.len() as u32;
    let mut verified = String::new();
    for (index, chunk) in chunks.iter().enumerate() {
        let answer = send(month, index as u32, parts, chunk)?;
        if index as u32 + 1 == parts {
            verified = answer;
        }
    }
    if verified != manifest.sha256 {
        return Err("archive_push_unverified".to_string());
    }
    let mut removed_local = false;
    if !keep_local {
        std::fs::remove_file(&path).map_err(|error| format!("archive_delete_failed: {error}"))?;
        removed_local = true;
    }
    Ok(PushReceipt {
        month: month.to_string(),
        to: node.to_string(),
        bytes: bytes.len() as u64,
        sha256: manifest.sha256.clone(),
        verified,
        removed_local,
    })
}

/// Receive one chunk of a push and, on the last, answer the digest of everything received.
///
/// The target side of [`push_to_node`]. The progress is on the **disk**, not in this struct: a chunk
/// arrives as its own call (a mesh call, or a CLI invocation after a restart), so "how much is here
/// already" has to be answerable from the directory. Two files under the archive directory:
///
/// ```text
/// whatsapp-archive-YYYY-MM.waa.incoming          the bytes received so far
/// whatsapp-archive-YYYY-MM.waa.incoming.parts    {"parts": n, "received": k}
/// ```
///
/// Only the completion of the file makes it an archive: the parts are verified (the framing, the
/// manifest's own digest, the month) before the `.incoming` file is renamed into place.
///
/// Nothing here needs the key, which is what lets a target prove arrival without being able to read a
/// message.
pub struct Sink {
    pub dir: PathBuf,
    pub month: String,
}

#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize)]
struct Progress {
    parts: u32,
    received: u32,
}

impl Sink {
    /// A sink for one month. A retried push starts from a clean slate, not from the tail of a failed one.
    pub fn new(dir: impl Into<PathBuf>, month: &str) -> Result<Sink, String> {
        month_bounds(month)?;
        let sink = Sink { dir: dir.into(), month: month.to_string() };
        let _ = std::fs::remove_file(sink.incoming());
        let _ = std::fs::remove_file(sink.progress());
        Ok(sink)
    }

    fn incoming(&self) -> PathBuf {
        self.dir.join(format!("{}.incoming", file_name(&self.month)))
    }

    fn progress(&self) -> PathBuf {
        self.dir.join(format!("{}.incoming.parts", file_name(&self.month)))
    }

    fn read_progress(&self) -> Progress {
        std::fs::read(self.progress())
            .ok()
            .and_then(|raw| serde_json::from_slice::<Progress>(&raw).ok())
            .unwrap_or_default()
    }

    fn write_progress(&self, progress: &Progress) -> Result<(), String> {
        std::fs::write(self.progress(), serde_json::to_vec(progress).unwrap_or_default())
            .map_err(|error| format!("archive_unwritable: {error}"))
    }

    fn reset(&self) {
        let _ = std::fs::remove_file(self.incoming());
        let _ = std::fs::remove_file(self.progress());
    }

    /// One chunk in; the answer is empty until the last, then the hex sha256 of the assembled file.
    pub fn accept(&self, part: u32, parts: u32, bytes: &[u8]) -> Result<String, String> {
        let progress = self.read_progress();
        if parts == 0 || part >= parts {
            return Err("archive_push_out_of_order".to_string());
        }
        if progress.parts != 0 && progress.parts != parts {
            return Err("archive_push_out_of_order".to_string());
        }
        if part != progress.received {
            return Err("archive_push_out_of_order".to_string());
        }
        std::fs::create_dir_all(&self.dir).map_err(|error| format!("archive_dir_unwritable: {error}"))?;
        {
            use std::io::Write;
            let mut file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(self.incoming())
                .map_err(|error| format!("archive_unwritable: {error}"))?;
            file.write_all(bytes).map_err(|error| format!("archive_unwritable: {error}"))?;
            file.sync_all().map_err(|error| format!("archive_unwritable: {error}"))?;
        }
        let next = Progress { parts, received: part + 1 };
        self.write_progress(&next)?;
        if next.received < parts {
            return Ok(String::new());
        }
        let incoming = self.incoming();
        let whole = read_file(&incoming)?;
        let manifest = match verify_bytes(&whole) {
            Ok(manifest) if manifest.month != self.month => Err("archive_month_mismatch".to_string()),
            Ok(manifest) => Ok(manifest),
            Err(reason) => Err(reason),
        };
        let manifest = match manifest {
            Ok(manifest) => manifest,
            Err(reason) => {
                // A refused push leaves nothing behind: not a partial file, not a file under the wrong
                // month's name.
                self.reset();
                return Err(reason);
            }
        };
        std::fs::rename(&incoming, self.dir.join(file_name(&self.month))).map_err(|error| format!("archive_rename_failed: {error}"))?;
        let _ = std::fs::remove_file(self.progress());
        Ok(manifest.sha256)
    }
}

/// Pseudo-random hex, so a fixture's payload does not compress to nothing and a chunked push is
/// measured on a file that really is several chunks.
fn noise(seed: u64, len: usize) -> String {
    let mut state = seed | 1;
    let mut out = String::with_capacity(len);
    while out.len() < len {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        out.push_str(&format!("{state:016x}"));
    }
    out.truncate(len);
    out
}

/// A `Memory` index with one month of messages in it, for a caller that wants a fixture.
///
/// Kept here rather than in the tests so the node's own capability tests can build the same shape.
pub fn fixture(month: &str, messages: usize) -> Memory {
    fixture_rich(month, messages, 0)
}

/// The same, with `text_len` characters of incompressible text in each body - a month that is really
/// as large as a month (used to measure a push that needs more than one chunk).
pub fn fixture_rich(month: &str, messages: usize, text_len: usize) -> Memory {
    let kv = Memory::new();
    let (start, _) = month_bounds(month).unwrap_or((0, 0));
    let chats = ["5511999999999@s.whatsapp.net", "120363000000000001@g.us"];
    for index in 0..messages {
        let chat = chats[index % chats.len()];
        let id = format!("3EB0{index:06}");
        let ts = start + 60_000 * (index as i64 % 400);
        let body = if text_len == 0 { format!("mensagem {index}") } else { noise(index as u64 + 1, text_len) };
        let record = format!(
            r#"{{"chat":"{chat}","id":"{id}","sender":"5511888888888@s.whatsapp.net","ts":{ts},"kind":"text","text":"{body}","source":"live"}}"#
        );
        let collected = crate::facts_of(chat, &id, ts, record.as_bytes());
        for (key, value) in collected.keys().into_iter().zip(collected.values(record.as_bytes())) {
            kv.set(key.as_bytes(), &value).unwrap();
        }
    }
    kv
}
