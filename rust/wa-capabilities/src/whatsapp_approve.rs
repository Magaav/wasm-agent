//! Operator approval of outgoing WhatsApp drafts: the gate, the queue of drafts, and the decision.
//!
//! The owner's question (13/11) is not "may the agent write" but "do I want this sentence to leave".
//! So the gate is not a policy on the agent and not a hook on a node: it is **one choke point**, in
//! `whatsapp_send::send`, which is where a send from anywhere in the fleet arrives - the account
//! node's own enqueue. A node without the gate cannot bypass it, because the gate is not configured
//! per caller; every caller's request becomes the same `OutboxRequest` on the same node, and this
//! module decides whether that request becomes a job or a draft.
//!
//! ```text
//! tool whatsapp_send {chat, text}
//!   -> validate                       (wa-whatsapp-outbox, unchanged)
//!   -> this node runs no component?   (unchanged: nothing is drafted where nothing can send)
//!   -> approval::gate(&verified)      -> None: the send continues exactly as before
//!                                    -> Some(draft): NOTHING is queued, the answer is `pending`
//!                                       with the draft's handle, and the tool waits on that handle
//! operator: /approve send|edit|reject <handle>
//!   -> decide -> (the policy check and the enqueue, once) -> the draft settles
//! caller:   the pending handle settles with the outcome
//! ```
//!
//! Why the draft is a FILE and not a queue job. The queue's contract is "the producer wrote it, the
//! worker settles it, nobody edits it" - and a draft is exactly the thing a person edits. It also has
//! to survive a restart and be readable by the operator's `/approve` without a worker running, and
//! writing it in the queue would make it look like a message somebody had already asked to send.
//!
//! The policy and the drafts live beside each other, per node, under the node's one root
//! (`docs/ONEROOT.md`): `<state root>/approve/policy.json` and `<state root>/approve/drafts/<handle>.json`.
//! `WA_APPROVE_DIR` moves the whole directory, which is what the tests use; nothing else reads a path.
//!
//! What this module must never do: send. It enqueues (through `whatsapp_send::enqueue`, the same
//! policy check and the same queue), and the component sends. A decision that a policy refuses is a
//! draft that settles `failed` with the policy's own word - never a silent drop.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// Where a node keeps the approval policy and the drafts waiting on it. Set by the tests (and by an
/// operator who keeps a second range); unset is the node's own root.
pub const DIR_ENV: &str = "WA_APPROVE_DIR";

/// The one decision file. `mode` is how the chat list is read: `all` gates every chat, `except`
/// gates every chat but the listed ones, `only` gates nothing but the listed ones.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Policy {
    #[serde(default)]
    pub version: u32,
    #[serde(default)]
    pub on: bool,
    #[serde(default)]
    pub mode: String,
    #[serde(default)]
    pub chats: Vec<String>,
    #[serde(default)]
    pub updated_at: i64,
}

impl Default for Policy {
    /// Off, and gating every chat if it is ever switched on: today's behaviour is the default, and a
    /// node that was never configured must not change what a send does.
    fn default() -> Policy {
        Policy { version: 1, on: false, mode: "all".into(), chats: Vec::new(), updated_at: 0 }
    }
}

impl Policy {
    /// The rule, in one place: is this exact JID gated? `mode` is read as data so a hand-edited file
    /// with an unknown mode is refused by `effective_mode` rather than guessed at.
    pub fn gates(&self, jid: &str) -> bool {
        if !self.on {
            return false;
        }
        let listed = self.chats.iter().any(|chat| chat == jid);
        match self.mode.as_str() {
            "only" => listed,
            "except" => !listed,
            // `all`, and anything a hand edit left unreadable: the safe direction for a switch whose
            // whole purpose is that nothing leaves without a person reading it is ON.
            _ => true,
        }
    }

    pub fn effective_mode(&self) -> &str {
        match self.mode.as_str() {
            "all" | "only" | "except" => self.mode.as_str(),
            _ => "all",
        }
    }
}

/// One message waiting for a decision. Written once when the gate stops the send, then updated only
/// by the decision (and by the job's outcome, read back from the queue).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Draft {
    pub handle: String,
    /// `pending`, then `sent`, `rejected` or `cancelled` - and `failed` when the policy refused the
    /// decision itself. Nothing else is ever written here.
    pub state: String,
    pub chat: String,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub mentions: Vec<String>,
    pub created_at: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decided_at: Option<i64>,
    /// The outbox job the decision enqueued, when it did.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job: Option<u64>,
    /// WhatsApp's id for the message, once the component settled the job.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    /// `unchanged` | `edited` | `rejected` | `cancelled`: what the operator did, not what happened to
    /// the message (which is `state` plus `message_id`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<String>,
    /// The exact text that was sent (the draft's own, or the operator's edit). Absent until a send.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub final_text: Option<String>,
    /// The operator's note on a rejection, or the word a failure settled with.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

// ---------------------------------------------------------------- paths

/// The approval directory of this node.
pub fn root() -> PathBuf {
    match std::env::var(DIR_ENV) {
        Ok(value) if !value.trim().is_empty() => PathBuf::from(value.trim()),
        _ => wa_host_support::paths::state_root().join("approve"),
    }
}

fn drafts_dir(root: &Path) -> PathBuf {
    root.join("drafts")
}

fn policy_path(root: &Path) -> PathBuf {
    root.join("policy.json")
}

fn draft_path(root: &Path, handle: &str) -> PathBuf {
    drafts_dir(root).join(format!("{handle}.json"))
}

/// A handle is `d-` and hex. It is a file name here, so the shape is checked before it is joined to a
/// path: a handle read from a message must never be able to name a file somewhere else.
pub fn handle_ok(handle: &str) -> bool {
    let rest = match handle.strip_prefix("d-") {
        Some(rest) => rest,
        None => return false,
    };
    !rest.is_empty() && rest.len() <= 32 && rest.chars().all(|c| c.is_ascii_hexdigit())
}

// ---------------------------------------------------------------- the policy file

/// This node's policy. A file that is absent, unreadable or not JSON is the default: OFF. That is the
/// one direction a broken switch may fail in - a message the operator wanted to approve going out is
/// a surprise, one that waits for a decision is not.
pub fn policy_at(root: &Path) -> Policy {
    let Ok(text) = std::fs::read_to_string(policy_path(root)) else {
        return Policy::default();
    };
    serde_json::from_str(&text).unwrap_or_default()
}

pub fn policy() -> Policy {
    policy_at(&root())
}

/// Write the policy, atomically: a reader never sees half a policy, and a crash leaves the old one.
pub fn write_policy_at(root: &Path, policy: &Policy) -> Result<(), String> {
    std::fs::create_dir_all(root).map_err(|error| error.to_string())?;
    let path = policy_path(root);
    let temp = path.with_extension(format!("json.tmp{}", std::process::id()));
    let text = serde_json::to_string_pretty(policy).map_err(|error| error.to_string())?;
    std::fs::write(&temp, text).map_err(|error| error.to_string())?;
    std::fs::rename(&temp, &path).map_err(|error| error.to_string())
}

// ---------------------------------------------------------------- the drafts

fn now_s() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .unwrap_or(0)
}

/// A handle that cannot collide within a node: the clock in microseconds, the process and a counter.
/// Not a digest, because there is nothing to hide and nothing to recompute - it is a name for a file.
fn new_handle() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let micros = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_micros() as u64)
        .unwrap_or(0);
    let nth = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("d-{:x}{:x}{:x}", micros, std::process::id() as u64, nth)
}

/// Write one draft, atomically and readable by its owner only.
fn save_draft_at(root: &Path, draft: &Draft) -> Result<(), String> {
    let dir = drafts_dir(root);
    wa_host_support::paths::private_dir(&dir);
    let path = draft_path(root, &draft.handle);
    let temp = path.with_extension("json.tmp");
    let text = serde_json::to_string(draft).map_err(|error| error.to_string())?;
    std::fs::write(&temp, text).map_err(|error| error.to_string())?;
    std::fs::rename(&temp, &path).map_err(|error| error.to_string())
}

pub fn read_at(root: &Path, handle: &str) -> Option<Draft> {
    if !handle_ok(handle) {
        return None;
    }
    let text = std::fs::read_to_string(draft_path(root, handle)).ok()?;
    serde_json::from_str(&text).ok()
}

/// Every draft this node holds, oldest first. A file that cannot be read is skipped: one unreadable
/// draft must not hide the others from the operator.
pub fn list_at(root: &Path) -> Vec<Draft> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(drafts_dir(root)) else {
        return out;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let Some(handle) = name.strip_suffix(".json") else { continue };
        if !handle_ok(handle) {
            continue;
        }
        if let Some(draft) = read_at(root, handle) {
            out.push(draft);
        }
    }
    out.sort_by(|a, b| a.created_at.cmp(&b.created_at).then_with(|| a.handle.cmp(&b.handle)));
    out
}

/// The answer `whatsapp_send` gives instead of a job. `effect` is `none` because nothing was queued -
/// the honest word, and the one a caller's steering fence reads.
pub fn pending_answer(draft: &Draft) -> Value {
    json!({
        "ok": true,
        "state": "pending",
        "draft": draft.handle,
        "approval": "waiting",
        "chat": draft.chat,
        "created_at": draft.created_at,
        "effect": "none",
        "note": "approval is on for this chat: nothing was queued. The message is a draft until the operator decides it.",
    })
}

/// The gate: Some(pending answer) when this chat is gated, in which case the draft now exists and the
/// send stops here. None means the send continues exactly as it did before this module existed.
///
/// The policy is read on every send. It is one small file, the answer has to be current (a switch an
/// operator just flipped must take effect on the next message, not at the next restart), and a draft
/// that waited on a cache is the failure this whole feature exists to prevent.
/// The gate, on this node's directory: `whatsapp_send` asks this one question before it queues.
pub fn gate(chat: &str, text: &str, reply_to: Option<&str>, mentions: &[String]) -> Option<Value> {
    gate_at(&root(), chat, text, reply_to, mentions)
}

pub fn gate_at(root: &Path, chat: &str, text: &str, reply_to: Option<&str>, mentions: &[String]) -> Option<Value> {
    let policy = policy_at(root);
    if !policy.gates(chat) {
        return None;
    }
    let draft = Draft {
        handle: new_handle(),
        state: "pending".into(),
        chat: chat.to_string(),
        text: text.to_string(),
        reply_to: reply_to.map(str::to_string),
        mentions: mentions.to_vec(),
        created_at: now_s(),
        ..Default::default()
    };
    match save_draft_at(root, &draft) {
        Ok(()) => Some(pending_answer(&draft)),
        // A gate that cannot write its draft is a gate that must not let the send through: the
        // message stays unsent and the answer says why.
        Err(error) => Some(json!({
            "ok": false,
            "error": "whatsapp_approve_draft_failed",
            "detail": error.chars().take(160).collect::<String>(),
            "effect": "none",
        })),
    }
}

// ---------------------------------------------------------------- the decision

/// One draft as a caller reads it. The record plus the one word a caller acts on: `state`.
pub fn view(draft: &Draft) -> Value {
    json!({
        "ok": true,
        "handle": draft.handle,
        "state": draft.state,
        "chat": draft.chat,
        "text": draft.text,
        "reply_to": draft.reply_to,
        "mentions": draft.mentions,
        "created_at": draft.created_at,
        "decided_at": draft.decided_at,
        "job": draft.job,
        "message_id": draft.message_id,
        "outcome": draft.outcome,
        "final": draft.final_text,
        "note": draft.note,
    })
}

/// `send` | `edit` | `reject` | `cancel`.
///
/// The three the operator has are one function because they are one transition: `pending` becomes
/// terminal exactly once, and the only difference is whether a job is written on the way out.
pub fn decide_at(root: &Path, handle: &str, decision: &str, text: Option<&str>, note: Option<&str>) -> Value {
    let Some(mut draft) = read_at(root, handle) else {
        return json!({"ok": false, "error": "whatsapp_approve_unknown_draft", "effect": "none"});
    };
    if draft.state != "pending" {
        // A decided draft is decided. A second `send` on the same handle would be a second message.
        return json!({
            "ok": false,
            "error": "whatsapp_approve_already_decided",
            "detail": format!("this draft is {}", draft.state),
            "draft": view(&draft),
            "effect": "none",
        });
    }
    let at = now_s();
    match decision {
        "reject" => {
            draft.state = "rejected".into();
            draft.outcome = Some("rejected".into());
            draft.decided_at = Some(at);
            draft.note = note.map(|text| text.chars().take(500).collect());
            if let Err(error) = save_draft_at(root, &draft) {
                return json!({"ok": false, "error": "whatsapp_approve_draft_failed",
                    "detail": error.chars().take(160).collect::<String>(), "effect": "none"});
            }
            json!({"ok": true, "draft": view(&draft), "effect": "none"})
        }
        "cancel" => {
            draft.state = "cancelled".into();
            draft.outcome = Some("cancelled".into());
            draft.decided_at = Some(at);
            draft.note = note.map(|text| text.chars().take(500).collect());
            if let Err(error) = save_draft_at(root, &draft) {
                return json!({"ok": false, "error": "whatsapp_approve_draft_failed",
                    "detail": error.chars().take(160).collect::<String>(), "effect": "none"});
            }
            json!({"ok": true, "draft": view(&draft), "effect": "none"})
        }
        "send" | "edit" => {
            let edited = decision == "edit";
            let final_text = match (edited, text) {
                (true, Some(value)) if !value.is_empty() => value.to_string(),
                (true, _) => {
                    return json!({"ok": false, "error": "whatsapp_approve_text_required",
                        "detail": "an edit needs the text to send", "effect": "none"})
                }
                (false, _) => draft.text.clone(),
            };
            // The enqueue is the same one every send takes: validate, ask the policy, write the job.
            let answer = crate::whatsapp_send::enqueue(
                &final_text,
                &draft.chat,
                draft.reply_to.as_deref(),
                &draft.mentions,
            );
            if answer["ok"] != json!(true) {
                // The policy refused the decision, so the draft does not stay pending: it settles
                // `failed` with the same word, and the agent's handle answers it.
                draft.state = "failed".into();
                draft.decided_at = Some(at);
                draft.note = Some(answer["error"].as_str().unwrap_or("refused").to_string());
                let _ = save_draft_at(root, &draft);
                let mut out = answer;
                out["draft"] = view(&draft);
                return out;
            }
            draft.state = "sent".into();
            draft.outcome = Some(if edited { "edited".into() } else { "unchanged".into() });
            draft.final_text = Some(final_text);
            draft.decided_at = Some(at);
            draft.job = answer["id"].as_u64();
            if let Err(error) = save_draft_at(root, &draft) {
                return json!({"ok": false, "error": "whatsapp_approve_draft_failed",
                    "detail": error.chars().take(160).collect::<String>(), "effect": "none"});
            }
            json!({"ok": true, "draft": view(&draft), "id": answer["id"], "queue": answer["queue"]})
        }
        other => json!({
            "ok": false,
            "error": "whatsapp_approve_unknown_decision",
            "detail": format!("{other} is not send, edit, reject or cancel"),
            "effect": "none",
        }),
    }
}

/// One draft, with the outbox job's outcome folded in when it has one.
///
/// This is the read the agent's pending handle makes, so it is also where a settled job becomes a
/// settled draft: `done` fills the message id, a terminal failure settles the draft `failed` with the
/// queue's reason. Reading is idempotent - it writes only the transition it just observed.
pub fn status_at(root: &Path, handle: &str) -> Value {
    let Some(mut draft) = read_at(root, handle) else {
        return json!({"ok": false, "error": "whatsapp_approve_unknown_draft", "effect": "none"});
    };
    if draft.state == "sent" {
        if let Some(job) = draft.job {
            let state = crate::whatsapp_send::job_state(job);
            if let Some(message_id) = state.get("message_id").and_then(Value::as_str) {
                draft.message_id = Some(message_id.to_string());
                let _ = save_draft_at(root, &draft);
            } else if let Some(word) = state.get("state").and_then(Value::as_str) {
                if word == "failed" || word == "dead" || word == "expired" {
                    draft.state = "failed".into();
                    if let Some(reason) = state.get("reason").and_then(Value::as_str) {
                        draft.note = Some(reason.to_string());
                    }
                    let _ = save_draft_at(root, &draft);
                }
            }
        }
    }
    json!({"ok": true, "draft": view(&draft)})
}

// ---------------------------------------------------------------- the capability

/// `host.whatsapp_approve({action, ...})`: the operator's door to the gate that `host.whatsapp_send`
/// meets. Four actions, one capability, because they are one object - the draft - and a caller that
/// can settle one must be able to see it.
pub extern "C-unwind" fn capability(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    let raw = wa_host_support::lua::arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => act(&request),
        Err(_) => json!({"ok": false, "error": "whatsapp_approve_invalid_request", "effect": "none"}),
    };
    wa_host_support::json::push_json(l, &answer);
    1
}

/// The capability's own dispatch, over this node's directory. `pub` so a test can call it with a root
/// of its own and no interpreter.
pub fn act(request: &Value) -> Value {
    act_at(&root(), request)
}

pub fn act_at(root: &Path, request: &Value) -> Value {
    let string = |key: &str| request.get(key).and_then(Value::as_str).map(str::to_string);
    match string("action").unwrap_or_default().as_str() {
        "status" => match string("draft") {
            Some(handle) => status_at(root, &handle),
            None => json!({"ok": false, "error": "whatsapp_approve_draft_required", "effect": "none"}),
        },
        "list" => {
            let drafts: Vec<Value> = list_at(root).iter().map(view).collect();
            let waiting = drafts.iter().filter(|row| row["state"] == json!("pending")).count();
            json!({"ok": true, "drafts": drafts, "waiting": waiting, "root": root.to_string_lossy()})
        }
        "policy" => {
            let policy = policy_at(root);
            json!({
                "ok": true,
                "on": policy.on,
                "mode": policy.effective_mode(),
                "chats": policy.chats,
                "updated_at": policy.updated_at,
            })
        }
        // The switch itself. It is a capability and not a file write in Lua because the policy must
        // change on the node that HOLDS THE ACCOUNT - the one whose `whatsapp_send` reads it - and an
        // operator typing `/approve on` in a chat on another node is asking that node, not this one.
        "policy_set" => {
            let on = request.get("on").and_then(Value::as_bool);
            let mode = string("mode");
            let chats: Option<Vec<String>> = request.get("chats").and_then(Value::as_array)
                .map(|items| items.iter().filter_map(Value::as_str).map(str::to_string).collect());
            if mode.as_deref().is_some_and(|mode| !matches!(mode, "all" | "only" | "except")) {
                return json!({"ok": false, "error": "whatsapp_approve_bad_mode",
                    "detail": "mode is all, only or except", "effect": "none"});
            }
            let mut policy = policy_at(root);
            policy.on = on.unwrap_or(policy.on);
            if let Some(mode) = mode {
                policy.mode = mode;
            }
            if let Some(chats) = chats {
                policy.chats = chats;
            }
            policy.version = 1;
            policy.updated_at = now_s();
            if let Err(error) = write_policy_at(root, &policy) {
                return json!({"ok": false, "error": "whatsapp_approve_policy_failed",
                    "detail": error.chars().take(160).collect::<String>(), "effect": "none"});
            }
            json!({"ok": true, "on": policy.on, "mode": policy.effective_mode(),
                "chats": policy.chats, "updated_at": policy.updated_at, "effect": "none"})
        }
        "decide" => {
            let Some(handle) = string("draft") else {
                return json!({"ok": false, "error": "whatsapp_approve_draft_required", "effect": "none"});
            };
            let Some(decision) = string("decision") else {
                return json!({"ok": false, "error": "whatsapp_approve_decision_required", "effect": "none"});
            };
            decide_at(root, &handle, &decision, string("text").as_deref(), string("note").as_deref())
        }
        other => json!({
            "ok": false,
            "error": "whatsapp_approve_unknown_action",
            "detail": format!("{other} is not status, list, policy, policy_set or decide"),
            "effect": "none",
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("wa-approve-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// THE RULE THE WHOLE FEATURE RESTS ON: the default is off, so a node nobody configured behaves
    /// exactly as it did before this file existed.
    #[test]
    fn a_node_nobody_configured_gates_nothing() {
        let root = scratch("default-off");
        let policy = policy_at(&root);
        assert!(!policy.on, "the default is off");
        assert_eq!(policy.effective_mode(), "all");
        assert!(gate_at(&root, "5511999999999@lid", "oi", None, &[]).is_none(), "an off switch drafts nothing");
        assert!(list_at(&root).is_empty(), "and writes no draft");
    }

    #[test]
    fn the_three_modes_gate_the_chats_they_say_and_no_others() {
        let all = Policy { on: true, mode: "all".into(), ..Policy::default() };
        assert!(all.gates("1@lid") && all.gates("2@g.us"));
        let except = Policy { on: true, mode: "except".into(), chats: vec!["1@lid".into()], ..Policy::default() };
        assert!(!except.gates("1@lid"), "a listed chat is the exception");
        assert!(except.gates("2@lid"), "and every other chat is gated");
        let only = Policy { on: true, mode: "only".into(), chats: vec!["1@lid".into()], ..Policy::default() };
        assert!(only.gates("1@lid") && !only.gates("2@lid"));
        // Off wins over every list.
        let off = Policy { on: false, mode: "only".into(), chats: vec!["1@lid".into()], ..Policy::default() };
        assert!(!off.gates("1@lid"));
        // A mode a hand edit broke reads as `all`: the safe direction is gating.
        let broken = Policy { on: true, mode: "sometimes".into(), ..Policy::default() };
        assert_eq!(broken.effective_mode(), "all");
        assert!(broken.gates("1@lid"));
    }

    #[test]
    fn the_policy_round_trips_and_a_broken_file_is_off() {
        let root = scratch("policy");
        let policy = Policy { on: true, mode: "only".into(), chats: vec!["1@lid".into()], updated_at: 7, ..Policy::default() };
        write_policy_at(&root, &policy).unwrap();
        assert_eq!(policy_at(&root), policy);
        std::fs::write(policy_path(&root), "{not json").unwrap();
        assert!(!policy_at(&root).on, "an unreadable switch is off, never on");
    }

    #[test]
    fn a_gated_send_becomes_a_draft_and_writes_no_job() {
        let root = scratch("gate");
        write_policy_at(&root, &Policy { on: true, mode: "all".into(), version: 1, ..Policy::default() }).unwrap();
        let answer = gate_at(&root, "5511999999999@lid", "the draft body", Some("3EB0"), &[]).expect("gated");
        assert_eq!(answer["state"], "pending");
        assert_eq!(answer["effect"], "none", "nothing was queued");
        assert!(answer.get("id").is_none(), "a draft is not a job");
        let handle = answer["draft"].as_str().unwrap().to_string();
        assert!(handle_ok(&handle));
        let draft = read_at(&root, &handle).unwrap();
        assert_eq!((draft.state.as_str(), draft.chat.as_str(), draft.text.as_str()), ("pending", "5511999999999@lid", "the draft body"));
        assert_eq!(draft.reply_to.as_deref(), Some("3EB0"));
        assert_eq!(list_at(&root).len(), 1);
        // A chat the policy does not gate is not drafted.
        write_policy_at(&root, &Policy { on: true, mode: "except".into(), chats: vec!["5511999999999@lid".into()], version: 1, ..Policy::default() }).unwrap();
        assert!(gate_at(&root, "5511999999999@lid", "x", None, &[]).is_none());
        assert_eq!(list_at(&root).len(), 1, "the second call drafted nothing");
    }

    #[test]
    fn a_handle_is_a_name_and_never_a_path() {
        for bad in ["", "d-", "d-../../etc/passwd", "x-1a", "d-zz", "d-1a/b"] {
            assert!(!handle_ok(bad), "{bad:?}");
            assert!(read_at(&scratch("handle"), bad).is_none(), "{bad:?}");
        }
        assert!(handle_ok("d-1a2b"));
    }

    #[test]
    fn a_rejection_settles_the_draft_and_queues_nothing() {
        let root = scratch("reject");
        write_policy_at(&root, &Policy { on: true, mode: "all".into(), version: 1, ..Policy::default() }).unwrap();
        let handle = gate_at(&root, "5511999999999@lid", "draft", None, &[])
            .and_then(|answer| answer["draft"].as_str().map(str::to_string)).unwrap();
        let answer = decide_at(&root, &handle, "reject", None, Some("not this time"));
        assert_eq!(answer["ok"], true);
        assert_eq!(answer["draft"]["state"], "rejected");
        assert_eq!(answer["draft"]["outcome"], "rejected");
        assert_eq!(answer["draft"]["note"], "not this time");
        assert!(answer["draft"]["job"].is_null(), "a rejection enqueues nothing");
        // A decided draft cannot be decided again: that would be a second message.
        let again = decide_at(&root, &handle, "send", None, None);
        assert_eq!(again["error"], "whatsapp_approve_already_decided");
        assert!(again.get("id").is_none() || again["id"].is_null());
    }

    #[test]
    fn a_cancel_is_the_operators_own_and_enqueues_nothing() {
        let root = scratch("cancel");
        write_policy_at(&root, &Policy { on: true, mode: "all".into(), version: 1, ..Policy::default() }).unwrap();
        let handle = gate_at(&root, "5511999999999@lid", "draft", None, &[])
            .and_then(|answer| answer["draft"].as_str().map(str::to_string)).unwrap();
        let answer = decide_at(&root, &handle, "cancel", None, None);
        assert_eq!(answer["draft"]["state"], "cancelled");
        assert_eq!(answer["draft"]["outcome"], "cancelled");
        assert!(answer["draft"]["job"].is_null());
    }

    #[test]
    fn an_unknown_decision_and_a_missing_edit_text_are_words() {
        let root = scratch("words");
        write_policy_at(&root, &Policy { on: true, mode: "all".into(), version: 1, ..Policy::default() }).unwrap();
        let handle = gate_at(&root, "5511999999999@lid", "draft", None, &[])
            .and_then(|answer| answer["draft"].as_str().map(str::to_string)).unwrap();
        assert_eq!(decide_at(&root, &handle, "shrug", None, None)["error"], "whatsapp_approve_unknown_decision");
        assert_eq!(decide_at(&root, &handle, "edit", None, None)["error"], "whatsapp_approve_text_required");
        assert_eq!(decide_at(&root, "d-nope", "send", None, None)["error"], "whatsapp_approve_unknown_draft");
        // And none of those refusals settled the draft.
        assert_eq!(read_at(&root, &handle).unwrap().state, "pending");
    }

    #[test]
    fn the_capability_answers_its_four_actions_and_refuses_the_rest() {
        let root = scratch("act");
        write_policy_at(&root, &Policy { on: true, mode: "all".into(), version: 1, ..Policy::default() }).unwrap();
        let listed = act_at(&root, &json!({"action": "policy"}));
        assert_eq!(listed["on"], true);
        assert_eq!(listed["mode"], "all");
        let empty = act_at(&root, &json!({"action": "list"}));
        assert_eq!(empty["waiting"], 0);
        gate_at(&root, "5511999999999@lid", "hi", None, &[]).unwrap();
        let listed = act_at(&root, &json!({"action": "list"}));
        assert_eq!(listed["waiting"], 1);
        assert_eq!(listed["drafts"][0]["text"], "hi");
        assert_eq!(act_at(&root, &json!({"action": "nope"}))["error"], "whatsapp_approve_unknown_action");
        assert_eq!(act_at(&root, &json!({"action": "status"}))["error"], "whatsapp_approve_draft_required");
    }

    #[test]
    fn the_switch_is_written_where_the_gate_reads_it() {
        let root = scratch("switch");
        // Off is the state a node starts in, and setting it says so without inventing a mode.
        let off = act_at(&root, &json!({"action": "policy_set", "on": false}));
        assert_eq!((off["on"].clone(), off["mode"].clone()), (json!(false), json!("all")));
        let on = act_at(&root, &json!({"action": "policy_set", "on": true, "mode": "only", "chats": ["1@lid"]}));
        assert_eq!(on["on"], true);
        assert_eq!(on["mode"], "only");
        // The gate now drafts that one chat and nothing else: the answer is not a file, it is a send.
        assert!(gate_at(&root, "1@lid", "oi", None, &[]).is_some());
        assert!(gate_at(&root, "2@lid", "oi", None, &[]).is_none());
        // A mode nobody defined is refused, and the policy is left as it was.
        assert_eq!(act_at(&root, &json!({"action": "policy_set", "mode": "sometimes"}))["error"], "whatsapp_approve_bad_mode");
        assert_eq!(policy_at(&root).mode, "only");
    }
}
