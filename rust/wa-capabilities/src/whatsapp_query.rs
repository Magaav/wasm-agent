//! `host.whatsapp_search`, `whatsapp_read`, `whatsapp_reactions`, `whatsapp_media`,
//! `whatsapp_download` and `whatsapp_backfill`: the agent's way into the message index the
//! `wa-whatsapp` component keeps.
//!
//! The architecture is the explicit send's (`rust/wa-capabilities/src/whatsapp_send.rs`,
//! `docs/SERVICE-COMPONENTS.md`): a question is a **job on the shared durable queue**, not a host call
//! into another component's state.
//!
//! ```text
//! tool whatsapp_search {q, chat?, kind?, from?, since?, until?, limit}
//!   -> validate + bound the request                 wa-whatsapp-index (shared crate)
//!   -> enqueue `whatsapp.query`, dedupe = the request itself        wa:queue
//! sfx component wa-whatsapp (granted queue worker on `whatsapp.query`)
//!   -> read its own kv index, settle done(answer) | fail(reason)
//! tool answer <- the settled result, inside MAX_RESULT_BYTES
//! ```
//!
//! Why the node waits instead of answering "queued": a search is a local kv read in a component that
//! is already running, and a model that has to poll for the answer to "what did they say" would spend a
//! turn doing it. The wait is bounded ([`wa_whatsapp_index::WAIT_MS`]) and heartbeats the node
//! (`serve::beat`) while it waits, so a slow answer is an answer ("still running, here is the id") and
//! never a frozen node. The dedupe key is the request itself, so a caller that asks again after a slow
//! answer reads the *same* job instead of queueing a second scan.
//!
//! `whatsapp_download` is the one that returns a file: the component decrypts and hands the plaintext
//! back on the job's progress stream (the queue's bounded byte channel), and this module writes it into
//! a bounded directory and answers with the path. Neither side ever returns the media key.
//!
//! Nothing here logs a message: the lines carry the op, the job id, a count and a size. The answer
//! carries text because a search result is text, and an answer is not a log.
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use wa_queue::{EnqueueRequest, JobId};
use wa_whatsapp_index as seam;

/// The component whose queue namespace this is (its manifest grants `queue.consume` on
/// `whatsapp.query`; `rust/components/wa-whatsapp/manifest.json`).
const COMPONENT: &str = "wa-whatsapp";
/// Poll interval while waiting for the answer. A component picks work up on its own tick, so a finer
/// poll only burns host calls.
const POLL: Duration = Duration::from_millis(20);
/// How long `whatsapp_download` waits for the decrypted bytes. Longer than a search (a CDN fetch plus a
/// decrypt), still bounded: a slow one answers "still running" and the same call reads the same job.
const DOWNLOAD_WAIT_MS: u64 = 10_000;
/// The directory the decrypted media lands in, under the components directory.
const DOWNLOAD_DIR: &str = "wa-whatsapp.downloads";
/// How many files that directory keeps before the oldest go.
const DOWNLOAD_KEEP_FILES: usize = 64;
/// How many bytes that directory keeps in total before the oldest go.
const DOWNLOAD_KEEP_BYTES: u64 = 64 * 1024 * 1024;

fn queue() -> wa_queue::Queue {
    wa_kernel_runtime::queue_host::node().queue(COMPONENT)
}

// ---- the six capabilities ---------------------------------------------------------------------

/// `host.whatsapp_search({q, chat?, kind?, from?, since?, until?, limit})`.
pub extern "C-unwind" fn search(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    answer(l, seam::Op::Search)
}

/// `host.whatsapp_read({chat, before?, limit})` - `chat` is an exact JID or a name to resolve.
pub extern "C-unwind" fn read(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    answer(l, seam::Op::Read)
}

/// `host.whatsapp_contacts({q?, limit?})` - which chats the index knows, by the name it observed.
///
/// The question that turns "Laura" into a chat (or into the several chats it could be), so a caller
/// never has to guess a number from a name.
pub extern "C-unwind" fn contacts(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    answer(l, seam::Op::Contacts)
}

/// `host.whatsapp_message({chat, id})` - one exact message, full stored text.
pub extern "C-unwind" fn message(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    answer(l, seam::Op::Message)
}

/// `host.whatsapp_reactions({chat, id})`.
pub extern "C-unwind" fn reactions(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    answer(l, seam::Op::Reactions)
}

/// `host.whatsapp_media({chat, id})`.
pub extern "C-unwind" fn media(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    answer(l, seam::Op::Media)
}

/// `host.whatsapp_download({chat, id})` - decrypt to the bounded directory and answer with the path.
pub extern "C-unwind" fn download(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(args) => component_absent(seam::Op::Download).unwrap_or_else(|| ask_download(&args)),
        Err(_) => seam::refusal(seam::Op::Download, "invalid_request", "the arguments are not a JSON object"),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

/// `host.whatsapp_backfill({chat?, count?})` - ask the primary phone for messages older than the
/// index holds.
///
/// The one query with an outward effect: the phone is asked, and the records that arrive land in the
/// index like any live message (marked `source: history`). It is still the same shape as the others -
/// validate, enqueue on `whatsapp.query`, wait - so nothing about the transport is special; the answer
/// is the request list the component made (`chats`, `count`) and a `note` when it stopped early, never
/// a message.
pub extern "C-unwind" fn backfill(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    answer(l, seam::Op::Backfill)
}

// ---- one query ---------------------------------------------------------------------------------

/// Why this node cannot answer a WhatsApp question at all, when it cannot: `Some((state, owner))`
/// means the `wa-whatsapp` component - the only thing that reads the index, sends from the outbox
/// and asks the phone - is not running here, so nothing on this node can settle the work.
///
/// `owner` is the node that was *told* it holds the account (`WASM_AGENT_WHATSAPP_OWNER`), which is
/// the deploy's own statement, never a guess from a name. `None` for the state means a CLI or
/// `WA_SCRIPT` process, which has no registry of its own and is skipped: only the serving node may
/// call its own absent component absent.
///
/// This is shared with `whatsapp_send` on purpose. A send issued on a node that runs no component
/// used to enqueue on that node's queue, where no worker exists: durable, never delivered, and
/// impossible to cancel once the tool had answered (#99). A node that cannot answer must not write
/// a job at all.
pub(crate) fn component_missing() -> Option<(String, Option<String>)> {
    if !crate::serve::serving() {
        return None;
    }
    let status = wa_kernel_runtime::services::status(Some(COMPONENT));
    if status["state"].as_str() == Some("running") {
        return None;
    }
    let owner = std::env::var("WASM_AGENT_WHATSAPP_OWNER").ok().filter(|value| !value.trim().is_empty());
    Some((status["state"].as_str().unwrap_or_default().to_string(), owner))
}

/// The honest answer when this node runs no `wa-whatsapp` component.
///
/// A question whose worker does not exist anywhere on this node is not slow: queueing it can only
/// end in `..._slow` and a retry that reads the same idle job. The account lives on exactly one
/// node, so the answer names it when the node was told (`WASM_AGENT_WHATSAPP_OWNER`) instead of
/// pretending the job is in flight. A CLI or `WA_SCRIPT` process has no registry of its own and is
/// skipped: only the serving node may call its own absent component absent.
fn component_absent(op: seam::Op) -> Option<Value> {
    let (state, owner) = component_missing()?;
    let detail = match &owner {
        Some(owner) => format!("this node runs no {COMPONENT} component; the WhatsApp account is served by {owner}"),
        None => format!("this node runs no {COMPONENT} component"),
    };
    let mut answer = seam::refusal(op, "whatsapp_component_absent", detail);
    answer["component"] = json!(COMPONENT);
    answer["state"] = json!(state);
    if let Some(owner) = owner {
        answer["owner"] = json!(owner);
    }
    Some(answer)
}

/// The common shape of the four text answers: validate, enqueue, wait, read the settled result.
fn answer(l: *mut wa_host_support::lua::LuaState, op: seam::Op) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(args) => component_absent(op).unwrap_or_else(|| ask(op, &args, seam::WAIT_MS)),
        Err(_) => seam::refusal(op, "invalid_request", "the arguments are not a JSON object"),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

/// Build the request from the tool's arguments, in the one shape the component reads back.
///
/// The count is one field on the wire and two names in the catalogue: `limit` for the ops that page an
/// answer, `count` for `whatsapp_backfill` (which asks the phone how many messages per chat, it does
/// not page anything). Either name is accepted for either op, so a caller that says `count` to a
/// search or `limit` to a backfill is understood instead of silently getting the default.
fn request_of(op: seam::Op, args: &Value) -> Result<seam::Verified, seam::Refusal> {
    let text = |key: &str| args.get(key).and_then(Value::as_str).map(str::to_string);
    let number = |key: &str| args.get(key).and_then(Value::as_i64);
    let limit = match op {
        seam::Op::Backfill => args.get("count").and_then(Value::as_u64).or_else(|| args.get("limit").and_then(Value::as_u64)),
        _ => args.get("limit").and_then(Value::as_u64).or_else(|| args.get("count").and_then(Value::as_u64)),
    };
    let request = seam::Request {
        op: op.as_str().to_string(),
        q: text("q"),
        chat: text("chat"),
        id: text("id"),
        kind: text("kind"),
        from: text("from"),
        since: number("since"),
        until: number("until"),
        before: text("before"),
        limit: limit.map(|value| value.min(u32::MAX as u64) as u32),
        max_bytes: args.get("max_bytes").and_then(Value::as_u64),
    };
    request.validate()
}

/// Validate, enqueue and wait for the component's answer.
fn ask(op: seam::Op, args: &Value, wait_ms: u64) -> Value {
    ask_in(&queue(), op, args, wait_ms)
}

/// The same, against a queue the caller owns: what the tests drive without touching the node's own
/// component directory.
fn ask_in(q: &wa_queue::Queue, op: seam::Op, args: &Value, wait_ms: u64) -> Value {
    let verified = match request_of(op, args) {
        Ok(verified) => verified,
        Err(refusal) => return seam::refusal(op, refusal.code, refusal.detail),
    };
    let id = match enqueue(q, &verified) {
        Ok(id) => id,
        Err(answer) => return answer,
    };
    settle(q, op, id, wait_ms)
}

fn enqueue(q: &wa_queue::Queue, verified: &seam::Verified) -> Result<u64, Value> {
    let op = verified.op;
    let request = verified.to_request();
    match q.enqueue(
        EnqueueRequest::new(seam::QUEUE, request.encode())
            .fresh_for(seam::FRESH_MS)
            .max_attempts(seam::MAX_ATTEMPTS)
            .dedupe(verified.dedupe_key()),
    ) {
        Ok(enqueued) => Ok(enqueued.id.0),
        Err(error) => Err(seam::refusal(op, "queue_failed", one_line(&error.to_string()))),
    }
}

/// Wait (bounded) for the job to settle, then turn it into the tool's answer.
///
/// A settled REFUSAL is answered at once, by its own word. Measured 13/11 on the account node itself
/// (`openclaw`, component built 01:10): a component that predates `contacts` refused the job `bad_op`,
/// the queue retried it and dead-lettered it, and this function answered
/// `whatsapp_contacts_failed state=dead` twenty seconds later - a permanent refusal dressed as a slow
/// query. Both halves are fixed: the component now SETTLES a payload it can never read with
/// [`seam::terminal_refusal`] (an answer, so no retry), and a dead job whose reason is permanent is
/// answered here with the seam's code (`whatsapp_contacts_bad_op`), so an older component on a node
/// still names its refusal instead of stalling.
fn settle(q: &wa_queue::Queue, op: seam::Op, id: u64, wait_ms: u64) -> Value {
    let deadline = Instant::now() + Duration::from_millis(wait_ms.max(1));
    loop {
        let job = match q.job(JobId(id)) {
            Ok(Some(job)) => job,
            Ok(None) => return seam::refusal(op, "job_lost", "the query job is not in the queue any more"),
            Err(error) => return seam::refusal(op, "queue_failed", one_line(&error.to_string())),
        };
        match job.state.as_str() {
            "done" => {
                let Some(result) = job.result.as_deref() else {
                    return seam::refusal(op, "answer_missing", "the query settled without a result");
                };
                let value: Value = match serde_json::from_slice::<Value>(result) {
                    Ok(value) => value,
                    Err(_) => return seam::refusal(op, "answer_unreadable", "the stored answer is not readable"),
                };
                if value.get("ok") == Some(&Value::Bool(false)) {
                    if let Some(code) = value.get("code").and_then(Value::as_str) {
                        return refused(op, code, value.get("detail").and_then(Value::as_str).unwrap_or_default(), value.get("op").and_then(Value::as_str));
                    }
                }
                return value;
            }
            "dead" | "expired" => {
                let reason = job.last_error.unwrap_or_else(|| job.state.as_str().to_string());
                if let Some(code) = seam::permanent_code(&reason) {
                    let mut answer = refused(op, code, &reason, None);
                    answer["state"] = Value::String(seam::state_word(job.state.as_str()).to_string());
                    return answer;
                }
                let mut answer = seam::refusal(op, "failed", reason.chars().take(160).collect::<String>());
                answer["state"] = Value::String(seam::state_word(job.state.as_str()).to_string());
                return answer;
            }
            state => {
                if Instant::now() >= deadline {
                    // Not an error: the component is working. The same call reads the same job.
                    return seam::slow(op, id, state);
                }
            }
        }
        crate::serve::beat();
        std::thread::sleep(POLL);
    }
}

/// The tool's answer for a refusal the component made: its own error word, and - when the code is
/// `bad_op`, the one disagreement a caller cannot fix by asking differently - the sentence that names
/// the skew. A component built before an op existed is the case this was measured on: the tool knows
/// the question, the installed component does not, and only an upgrade on that node can settle it.
fn refused(op: seam::Op, code: &str, detail: &str, asked_op: Option<&str>) -> Value {
    let mut answer = seam::refusal(op, code, detail);
    if let Some(asked) = asked_op.filter(|asked| !asked.is_empty() && *asked != op.as_str()) {
        answer["component_op"] = json!(asked);
    }
    if code == "bad_op" {
        answer["state"] = json!("refused");
        answer["note"] = json!(format!(
            "the installed {COMPONENT} component does not know this op: it was built before it existed. Upgrade the component on the node that holds the account (`wa services upgrade {COMPONENT}`); nothing is retried."
        ));
    }
    answer
}

// ---- download ----------------------------------------------------------------------------------

fn ask_download(args: &Value) -> Value {
    ask_download_in(&queue(), args, DOWNLOAD_WAIT_MS)
}

fn ask_download_in(q: &wa_queue::Queue, args: &Value, wait_ms: u64) -> Value {
    let verified = match request_of(seam::Op::Download, args) {
        Ok(verified) => verified,
        Err(refusal) => return seam::refusal(seam::Op::Download, refusal.code, refusal.detail),
    };
    let id = match enqueue(q, &verified) {
        Ok(id) => id,
        Err(answer) => return answer,
    };
    let answer = settle(q, seam::Op::Download, id, wait_ms);
    if answer["ok"] != Value::Bool(true) {
        return answer;
    }
    let manifest = match seam::Download::decode(&serde_json::to_vec(&answer).unwrap_or_default()) {
        Some(manifest) => manifest,
        None => return seam::refusal(seam::Op::Download, "answer_unreadable", "the download manifest is not readable"),
    };
    match collect_in(q, id, &manifest) {
        Ok(bytes) => match store(&manifest, &bytes) {
            Ok(path) => json!({
                "ok": true,
                "op": "download",
                "chat": manifest.chat,
                "id": manifest.id,
                "kind": manifest.kind,
                "mime": manifest.mime,
                "filename": manifest.filename,
                "bytes": manifest.bytes,
                "sha256": manifest.sha256,
                "path": path,
                "note": "the bytes are in this node's component directory, in a bounded download folder",
            }),
            Err(refusal) => seam::refusal(seam::Op::Download, "write_failed", refusal),
        },
        Err((code, detail)) => seam::refusal(seam::Op::Download, code, detail),
    }
}

/// Collect the chunks of the **last** download attempt of this job.
///
/// Progress is append-only, so an attempt that failed after writing half a file leaves its chunks
/// behind; each attempt starts with a header naming the job ([`seam::download_header`]). The reader
/// takes the last header and the `manifest.chunks` entries that follow it - never a concatenation of
/// two half files - then checks the length and the hash before handing anything to disk.
fn collect_in(q: &wa_queue::Queue, id: u64, manifest: &seam::Download) -> Result<Vec<u8>, (&'static str, String)> {
    let entries = match q.progress_since(JobId(id), 0, 1024) {
        Ok(entries) => entries,
        Err(error) => return Err(("progress_unreadable", one_line(&error.to_string()))),
    };
    let start = entries
        .iter()
        .rposition(|entry| seam::download_header_job(&entry.bytes) == Some(id))
        .ok_or(("progress_missing", "the job carries no download header".to_string()))?;
    let wanted = manifest.chunks as usize;
    let chunks: Vec<&[u8]> = entries[start + 1..].iter().take(wanted).map(|entry| entry.bytes.as_slice()).collect();
    if chunks.len() != wanted {
        return Err((
            "progress_incomplete",
            format!("{} of {wanted} chunks are stored", chunks.len()),
        ));
    }
    let mut bytes = Vec::with_capacity(manifest.bytes as usize);
    for chunk in chunks {
        bytes.extend_from_slice(chunk);
    }
    if bytes.len() as u64 != manifest.bytes {
        return Err((
            "size_mismatch",
            format!("{} bytes stored, {} announced", bytes.len(), manifest.bytes),
        ));
    }
    if !manifest.sha256.is_empty() && !manifest.sha256.eq_ignore_ascii_case(&sha256_hex(&bytes)) {
        return Err(("hash_mismatch", "the decrypted bytes do not hash to the message's own digest".to_string()));
    }
    Ok(bytes)
}

/// Where the media lands: `<components>/wa-whatsapp.downloads/`, pruned to a bounded number of files
/// and a bounded number of bytes before the new file is written.
fn store(manifest: &seam::Download, bytes: &[u8]) -> Result<String, String> {
    let dir = wa_host_support::paths::component_dir().join(DOWNLOAD_DIR);
    std::fs::create_dir_all(&dir).map_err(|error| format!("download dir: {error}"))?;
    prune_dir(&dir, bytes.len() as u64);
    let path = dir.join(file_name(manifest));
    std::fs::write(&path, bytes).map_err(|error| format!("write: {error}"))?;
    Ok(path.to_string_lossy().into_owned())
}

/// A filename an operator can recognise and a filesystem cannot be hurt by: the message id, the
/// sender's own name for the file, and the extension its MIME type implies. No path separators, no
/// leading dot, nothing a filesystem refuses.
fn file_name(manifest: &seam::Download) -> String {
    let safe_id: String = manifest.id.chars().filter(char::is_ascii_alphanumeric).take(24).collect();
    let cleaned: String = manifest
        .filename
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.') { ch } else { '_' })
        .take(80)
        .collect();
    // An extension is the short alphanumeric tail after the last dot; anything else is part of the
    // name, where a dot becomes an underscore (`..` is a path, not a name).
    let (stem, extension) = match cleaned.rsplit_once('.') {
        Some((stem, ext)) if !ext.is_empty() && ext.len() <= 5 && ext.chars().all(|ch| ch.is_ascii_alphanumeric()) => {
            (stem.to_string(), ext.to_ascii_lowercase())
        }
        _ => (cleaned.clone(), extension_for_mime(&manifest.mime).to_string()),
    };
    let stem: String = stem.trim_matches(|ch| ch == '.' || ch == '_').chars().map(|ch| if ch == '.' { '_' } else { ch }).take(60).collect();
    let stem = if stem.is_empty() { "media".to_string() } else { stem };
    let safe_id = if safe_id.is_empty() { "media".to_string() } else { safe_id };
    format!("{safe_id}-{stem}.{extension}")
}

fn extension_for_mime(mime: &str) -> &'static str {
    match mime.split(';').next().unwrap_or("").trim() {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/webp" => "webp",
        "image/gif" => "gif",
        "video/mp4" => "mp4",
        "video/3gpp" => "3gp",
        "audio/ogg" => "ogg",
        "audio/mpeg" => "mp3",
        "audio/mp4" => "m4a",
        "application/pdf" => "pdf",
        _ => "bin",
    }
}

/// Keep the download directory bounded: the oldest files go first, by modification time, until the
/// directory (with the file about to be written counted in) is inside both bounds.
fn prune_dir(dir: &Path, incoming: u64) {
    prune_to(dir, incoming, DOWNLOAD_KEEP_FILES, DOWNLOAD_KEEP_BYTES)
}

/// The bounds as arguments, so a test can measure the rule with five small files instead of 64 MiB.
fn prune_to(dir: &Path, incoming: u64, keep_files: usize, keep_bytes: u64) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut files: Vec<(std::time::SystemTime, u64, PathBuf)> = entries
        .flatten()
        .filter_map(|entry| {
            let meta = entry.metadata().ok()?;
            if !meta.is_file() {
                return None;
            }
            Some((meta.modified().unwrap_or(std::time::UNIX_EPOCH), meta.len(), entry.path()))
        })
        .collect();
    files.sort_by_key(|(time, _, _)| *time);
    let mut count = files.len() + 1;
    let mut total: u64 = files.iter().map(|(_, size, _)| *size).sum::<u64>().saturating_add(incoming);
    while (count > keep_files || total > keep_bytes) && !files.is_empty() {
        let (_, size, path) = files.remove(0);
        // A file that refuses to go is counted as if it were gone rather than looping on it: the next
        // call tries again, and the answer says what was written, not what was not cleaned.
        total = total.saturating_sub(size);
        count = count.saturating_sub(1);
        let _ = std::fs::remove_file(path);
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    use ring::digest::{digest, SHA256};
    digest(&SHA256, bytes).as_ref().iter().map(|byte| format!("{byte:02x}")).collect()
}

/// One bounded line: a reason is a log field and an answer, not a place a multi-line error can break
/// the line it lands in.
fn one_line(text: &str) -> String {
    text.chars().map(|ch| if ch.is_control() { ' ' } else { ch }).take(160).collect()
}

#[cfg(test)]
mod tests;
