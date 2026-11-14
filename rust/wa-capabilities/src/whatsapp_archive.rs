//! `host.whatsapp_archive`: retention's other half - the monthly cut, the encrypted archive file, the
//! push to another disk or node, and `wa whatsapp archive list|restore|unload`.
//!
//! The live index keeps 180 days (`index_retention_days`, `rust/components/wa-whatsapp/src/guest.rs`).
//! What falls out of it is not deleted: once a month the oldest month entirely outside that window is
//! cut into ONE file, `whatsapp-archive-YYYY-MM.waa`, compressed and sealed with the node's keystore,
//! kept up to 360 days from the message date and restorable on demand. The rules, the file format and
//! the promises are `docs/WHATSAPP-ARCHIVE.md`; the operations themselves are
//! `rust/wa-whatsapp-archive`, which is pure (a kv trait, a sealer trait, a directory) so every one of
//! them is measured in `cargo test` on a machine that never paired a phone.
//!
//! Why the node does this and not the component: an archive is a **file** - on another disk, on
//! another node - and a component's world has no filesystem (`rust/components/wa-whatsapp/wit/wa.wit`).
//! The index it cuts is the component's kv namespace, which the host owns and already administers
//! (`wa_kernel_runtime::state_host`: export, import, verify, snapshots) - so the cut reads and removes
//! the very keys the component wrote, using the layout and the tokenizer both ends share
//! (`wa_whatsapp_index::keys`, `wa_whatsapp_index::text`) instead of a second copy of them.
//!
//! What the component does with this, and why the two halves are not one: a restored month is marked
//! (`restored: true` on the record, `ix/arc/<month>` in the kv), retention walks past its range instead
//! of deleting it again, and an answer built from it says so (`restored`, `restored_month`).
//!
//! Nothing here prints a message, a chat id or a key: the answers carry a month, counts, a digest, a
//! path and a node name. The key never leaves the keystore - `seal`/`open` take a context and bytes.
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use wa_whatsapp_archive as archive;
// The archive crate's two seams are what this module implements; the trait has to be in scope for the
// methods to resolve on the adapters below.
use wa_whatsapp_archive::Kv as _;

/// The component whose kv namespace holds the index.
const COMPONENT: &str = "wa-whatsapp";
/// The keystore namespace the archive's key is derived under (a name, never a key).
const SEAL_NAMESPACE: &str = archive::SEAL_NAMESPACE;
/// The operator's live-index window when the definition says nothing (`index_retention_days`).
const DEFAULT_KEEP_DAYS: u32 = 180;

// ---- the two seams, over the node's own storage and key -------------------------------------------

/// The index, as the node sees it: the component's kv namespace, opened by the host that owns it.
struct Index(wa_kv::Namespaced<wa_kernel_runtime::state_host::HostStore>);

impl archive::Kv for Index {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, String> {
        self.0.get(key)
    }

    fn set(&self, key: &[u8], value: &[u8]) -> Result<(), String> {
        self.0.put(key, value)
    }

    fn del(&self, key: &[u8]) -> Result<(), String> {
        self.0.del(key)
    }

    fn scan(&self, prefix: &[u8], cursor: Option<Vec<u8>>, limit: usize) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
        self.0.scan_page(prefix, cursor.as_deref(), limit)
    }
}

/// The keystore's keyless seal/open, for this one namespace.
struct Seal(wa_keystore::NamespacedSealer);

impl archive::Sealer for Seal {
    fn seal(&self, context: &str, plaintext: &[u8]) -> Result<Vec<u8>, String> {
        use wa_keystore::Sealer as _;
        self.0.seal(context, plaintext).map_err(|error| format!("archive_seal_failed:{}", error.reason()))
    }

    fn open(&self, context: &str, sealed: &[u8]) -> Result<Vec<u8>, String> {
        use wa_keystore::Sealer as _;
        self.0.open(context, sealed).map(|opened| opened.to_vec()).map_err(|error| format!("archive_open_failed:{}", error.reason()))
    }
}

fn index_in(components: &Path) -> Index {
    Index(wa_kernel_runtime::state_host::namespace_in(components, COMPONENT))
}

/// The node's keystore, at `dir`. `passphrase` is for a host with neither DPAPI nor a kernel keyring
/// (and for the tests, which run on whatever the build machine has): the operator's own passphrase is
/// read from the environment by `Options::from_env`, never from here.
fn sealer_at(dir: &Path, passphrase: Option<&str>) -> Result<Seal, String> {
    let mut options = wa_keystore::Options::from_env(dir);
    if let Some(passphrase) = passphrase {
        options = options.with_protection(wa_keystore::Protection::PassphraseFile).with_passphrase(passphrase);
    }
    let mut keystore = wa_keystore::Keystore::open(&options).map_err(|error| format!("archive_keystore:{}", error.reason()))?;
    keystore.ensure_root().map_err(|error| format!("archive_keystore:{}", error.reason()))?;
    let keystore = std::sync::Arc::new(keystore);
    Ok(Seal(keystore.for_namespace(SEAL_NAMESPACE)))
}

// ---- what the archive records about the data it holds ----------------------------------------------

/// Which build and schema wrote the data, read out of the namespace's own meta (the same two facts
/// `wa state status` answers with). An absent one is empty, never a guess.
fn build_of(components: &Path) -> archive::Build {
    let kv = index_in(components);
    let read = |key: &str| {
        kv.get(key.as_bytes())
            .ok()
            .flatten()
            .map(|raw| String::from_utf8_lossy(&raw).trim().to_string())
            .unwrap_or_default()
    };
    archive::Build { component_version: read("__wa/meta/component-version"), schema: read("__wa/meta/schema") }
}

/// How long the live index keeps a message: the caller's `keep_days`, else this node's setting
/// (`WA_WHATSAPP_KEEP_DAYS`), else the component's own default.
///
/// It must be the `index_retention_days` the component was started with - the window that decides what
/// the component prunes and what the archive may cut - and every answer carries the value used, so a
/// node whose two disagree can see it instead of losing a month to the disagreement
/// (`docs/WHATSAPP-ARCHIVE.md`).
fn keep_days(requested: Option<u64>) -> u32 {
    if let Some(days) = requested {
        return (days as u32).clamp(1, 3650);
    }
    std::env::var("WA_WHATSAPP_KEEP_DAYS")
        .ok()
        .and_then(|value| value.trim().parse::<u32>().ok())
        .map(|days| days.clamp(1, 3650))
        .unwrap_or(DEFAULT_KEEP_DAYS)
}

/// Where the archives live: under the node's components directory, beside the state they came from.
fn archive_dir() -> PathBuf {
    archive::dir_in(&wa_host_support::paths::component_dir())
}

/// Where a pushed archive goes when the caller does not say: the operator's setting
/// (`WA_WHATSAPP_ARCHIVE_PUSH`, a node name or a directory), else the nextcloud node - which is the
/// node this fabric keeps cold data on.
fn push_target(requested: Option<&str>) -> String {
    if let Some(target) = requested.map(str::trim).filter(|target| !target.is_empty()) {
        return target.to_string();
    }
    std::env::var("WA_WHATSAPP_ARCHIVE_PUSH")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "nextcloud".to_string())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|elapsed| elapsed.as_millis() as i64).unwrap_or(0)
}

fn month_arg(request: &Value) -> Result<String, String> {
    let month = request.get("month").and_then(Value::as_str).unwrap_or_default().trim().to_string();
    wa_whatsapp_index::month::is_month(&month).then_some(month).ok_or_else(|| "archive_month_required".to_string())
}

// ---- one request ---------------------------------------------------------------------------------

/// One request, against an explicit components directory (what the tests use, so nothing here has to
/// make `WA_COMPONENTS_DIR` process-wide).
pub fn run_in(components: &Path, request: &Value) -> Value {
    run_with(components, &crate::vault_cli::vault_dir(), None, request)
}

/// The same, with the keystore named explicitly - what a test needs, so nothing here has to make a
/// keystore directory (or a passphrase) process-wide.
pub fn run_with(components: &Path, keystore: &Path, passphrase: Option<&str>, request: &Value) -> Value {
    let dir = archive::dir_in(components);
    let index = index_in(components);
    let action = request.get("action").and_then(Value::as_str).unwrap_or_default();
    let answer = (|| -> Result<Value, String> {
        match action {
            "status" | "list" => {
                let archives = archive::list(&index, &dir)?;
                let due = archive::due(&index, now_ms(), keep_days(None))?;
                let restored = archive::restored_months(&index)?;
                Ok(json!({
                    "ok": true,
                    "action": "list",
                    "dir": dir.to_string_lossy(),
                    "keep_days": keep_days(None),
                    "keep_after_month_days": archive::KEEP_AFTER_MONTH_DAYS,
                    "push_target": push_target(None),
                    "due": due,
                    "restored": restored,
                    "archives": archives.iter().map(|row| serde_json::to_value(row).unwrap_or(Value::Null)).collect::<Vec<_>>(),
                }))
            }
            "cut" => {
                let keep = keep_days(request.get("keep_days").and_then(Value::as_u64));
                let month = match request.get("month").and_then(Value::as_str) {
                    // A month the caller names is still a month the window must agree with: the cut
                    // never moves a message out of the live index while the component is still keeping
                    // it, whatever the caller asked for.
                    Some(month) if !month.trim().is_empty() => {
                        let month = month.trim().to_string();
                        if !archive::is_due(&month, now_ms(), keep)? {
                            return Err("archive_month_not_due".to_string());
                        }
                        month
                    }
                    _ => match archive::due(&index, now_ms(), keep)? {
                        Some(month) => month,
                        None => {
                            return Ok(json!({
                                "ok": true,
                                "action": "cut",
                                "cut": Value::Null,
                                "nothing_due": true,
                                "keep_days": keep_days(None),
                                "detail": "no month is entirely outside the window",
                            }))
                        }
                    },
                };
                let sealer = sealer_at(keystore, passphrase)?;
                let build = build_of(components);
                let cut = archive::cut(&index, &sealer, &dir, &month, now_ms(), &build)?;
                Ok(json!({
                    "ok": true,
                    "action": "cut",
                    "month": cut.month,
                    "chats": cut.chats,
                    "messages": cut.messages,
                    "entries": cut.entries,
                    "bytes": cut.bytes,
                    "sha256": cut.sha256,
                    "path": cut.path.to_string_lossy(),
                    "written": cut.written,
                    "component_version": build.component_version,
                    "schema": build.schema,
                }))
            }
            "restore" => {
                let month = month_arg(request)?;
                let sealer = sealer_at(keystore, passphrase)?;
                let restored = archive::restore(&index, &sealer, &dir, &month, now_ms())?;
                Ok(json!({
                    "ok": true,
                    "action": "restore",
                    "month": restored.month,
                    "entries": restored.entries,
                    "messages": restored.messages,
                    "sha256": restored.sha256,
                    "again": restored.again,
                    "read_only": true,
                }))
            }
            "unload" => {
                let month = month_arg(request)?;
                let unloaded = archive::unload(&index, &month, &dir)?;
                Ok(json!({
                    "ok": true,
                    "action": "unload",
                    "month": unloaded.month,
                    "entries": unloaded.entries,
                    "messages": unloaded.messages,
                    "was_restored": unloaded.was_restored,
                }))
            }
            "expire" => {
                let expired = archive::expire(&index, &dir, now_ms())?;
                Ok(json!({"ok": true, "action": "expire", "expired": expired, "keep_after_month_days": archive::KEEP_AFTER_MONTH_DAYS}))
            }
            "push" => {
                let month = match request.get("month").and_then(Value::as_str) {
                    Some(month) if !month.trim().is_empty() => month.trim().to_string(),
                    _ => archive::due(&index, now_ms(), keep_days(request.get("keep_days").and_then(Value::as_u64)))?
                        .ok_or_else(|| "archive_month_required".to_string())?,
                };
                let keep_local = request.get("keep_local").and_then(Value::as_bool).unwrap_or(false);
                let target = push_target(request.get("to").and_then(Value::as_str));
                if looks_like_a_path(&target) {
                    let receipt = archive::push_to_dir(&dir, &month, Path::new(&target), keep_local)?;
                    return Ok(json!({
                        "ok": true, "action": "push", "month": receipt.month, "to": receipt.to,
                        "bytes": receipt.bytes, "sha256": receipt.sha256, "verified": receipt.verified,
                        "removed_local": receipt.removed_local, "transport": "disk",
                    }));
                }
                let mut send = |month: &str, part: u32, parts: u32, bytes: &[u8]| -> Result<String, String> {
                    send_chunk(&target, month, part, parts, bytes)
                };
                let receipt = archive::push_to_node(&dir, &month, &target, keep_local, &mut send)?;
                Ok(json!({
                    "ok": true, "action": "push", "month": receipt.month, "to": receipt.to,
                    "bytes": receipt.bytes, "sha256": receipt.sha256, "verified": receipt.verified,
                    "removed_local": receipt.removed_local, "transport": "mesh",
                }))
            }
            "receive" => {
                // The node side of a push: chunks in, the assembled file verified, and the digest the
                // sender compares against its own before it deletes anything.
                let month = month_arg(request)?;
                let part = request.get("part").and_then(Value::as_u64).unwrap_or(0) as u32;
                let parts = request.get("parts").and_then(Value::as_u64).unwrap_or(1).max(1) as u32;
                let bytes = request.get("bytes").and_then(Value::as_str).map(hex_decode).transpose()?.unwrap_or_default();
                // The sink's progress is the file on the disk, not a field in memory: a chunk that
                // arrives after a restart lands in the right place.
                let sink = archive::Sink { dir, month: month.clone() };
                let digest = sink.accept(part, parts, &bytes)?;
                Ok(json!({
                    "ok": true, "action": "receive", "month": month, "part": part, "parts": parts,
                    "bytes": bytes.len(), "sha256": digest, "complete": part + 1 == parts,
                }))
            }
            other => Err(format!("archive_action_unknown:{other}")),
        }
    })();
    answer.unwrap_or_else(|error| json!({"ok": false, "action": action, "error": error}))
}

/// Whether a push target names a directory rather than a node.
///
/// A directory is what an operator writes when the archive goes to another disk: an absolute path, a
/// `~`, or anything with a separator in it. A node name is a single word (`nextcloud`, `openclaw`).
fn looks_like_a_path(target: &str) -> bool {
    target.starts_with('/') || target.starts_with('~') || target.starts_with('.') || target.contains('/') || target.contains('\\')
}

/// One chunk over the mesh, on the same transport every peer call uses.
///
/// The peer's answer is the `receive` result: on the last chunk it carries the digest it computed over
/// the whole assembled file, which is the only thing that makes a push "verified".
fn send_chunk(node: &str, month: &str, part: u32, parts: u32, bytes: &[u8]) -> Result<String, String> {
    let request = json!({
        "node": node,
        "capability": "whatsapp_archive",
        "args": {"action": "receive", "month": month, "part": part, "parts": parts, "bytes": hex_encode(bytes)},
        "timeout_seconds": 120,
    });
    let answer = wa_mesh::host_call::dispatch(&request);
    if answer.get("ok").and_then(Value::as_bool) != Some(true) {
        let reason = answer
            .get("error")
            .and_then(Value::as_str)
            .or_else(|| answer.get("reason").and_then(Value::as_str))
            .or_else(|| answer.get("detail").and_then(Value::as_str))
            .unwrap_or("unreachable");
        return Err(format!("archive_push_failed:{reason}"));
    }
    // The signed reply's `body` is the peer's own answer to `receive`.
    let body = answer.get("body").and_then(Value::as_str).unwrap_or_default();
    let received: Value = serde_json::from_str(body).map_err(|_| "archive_push_answer_unreadable".to_string())?;
    if received.get("ok").and_then(Value::as_bool) != Some(true) {
        let reason = received.get("error").and_then(Value::as_str).unwrap_or("refused");
        return Err(format!("archive_push_failed:{reason}"));
    }
    Ok(received.get("sha256").and_then(Value::as_str).unwrap_or_default().to_string())
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn hex_decode(text: &str) -> Result<Vec<u8>, String> {
    let text = text.trim();
    if text.len() % 2 != 0 {
        return Err("archive_bytes_invalid".to_string());
    }
    let mut out = Vec::with_capacity(text.len() / 2);
    let bytes = text.as_bytes();
    for pair in bytes.chunks(2) {
        let byte = u8::from_str_radix(std::str::from_utf8(pair).map_err(|_| "archive_bytes_invalid".to_string())?, 16)
            .map_err(|_| "archive_bytes_invalid".to_string())?;
        out.push(byte);
    }
    Ok(out)
}

/// `host.whatsapp_archive({action, month?, to?, keep_local?})`.
pub extern "C-unwind" fn capability(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => run_in(&wa_host_support::paths::component_dir(), &request),
        Err(_) => json!({"ok": false, "error": "archive_request_invalid"}),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

#[cfg(test)]
mod tests;
