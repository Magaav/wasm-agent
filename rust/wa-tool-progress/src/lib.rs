//! The live files a progress row is written to and read from - and nothing about what a row says.
//!
//! The drawing (what a row looks like, from facts and a clock) is `wa-tool-progress-format`, which this
//! crate depends on and re-exports: every name that used to live here still resolves here, so no caller
//! changes. What stays is the part that touches the world - the environment a data directory comes from,
//! the owner key a session gets, and the atomic write of one file.

pub use wa_tool_progress_format::*;

pub mod build;
pub mod render;

use serde_json::Value;

pub const SECRET_ENV: &[&str] = &[
    "WASM_AGENT_LLM_API_KEY",
    "OPENAI_API_KEY",
    "OPENCODE_GO_API_KEY",
    "WASM_AGENT_PROMPT_CACHE_KEY",
];

/// Those values from the process environment, as `wa-operation` does it: a value shorter than eight
/// bytes would redact ordinary text.
pub fn env_secrets() -> Vec<String> {
    let mut values = Vec::new();
    for name in SECRET_ENV {
        if let Ok(value) = std::env::var(name) {
            if value.len() >= 8 { values.push(value); }
        }
    }
    values
}

/// Where the node's data goes: `$WASM_AGENT_DATA`, else `$WASM_AGENT_HOME/.wasm-agent`, else
/// `$HOME/.wasm-agent` - the three tiers `scripts/lib/build-status.sh` uses for the build loader.
/// The host writes it and every renderer reads it, which is what lets the CLI, the window and the
/// native editor agree about a call none of them can poll while Lua is blocked.
pub fn data_dir() -> std::path::PathBuf {
    let env = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
    let data = env("WASM_AGENT_DATA").or_else(|| env("WASM_AGENT_HOME").map(|home| format!("{home}/.wasm-agent")))
        .or_else(|| env("HOME").map(|home| format!("{home}/.wasm-agent")))
        .unwrap_or_else(|| ".wasm-agent".to_string());
    std::path::PathBuf::from(data)
}

/// Where the live files go: **one file per owning session**, under `<data>/tool-progress/`.
///
/// It used to be one file for the whole node (`<data>/tool-progress.json`): one slot, one throttle,
/// no owner. Three consequences, all measured by the session-isolation audit (18/11, finding 1): a row
/// could only ever describe "the call this process happened to see"; every session's reader drew
/// whatever had been written last; and `finish` blanked every reader's row at once. Worst of all the
/// row carries the last line of the owner's stdout, so the leak was content and not only a label.
///
/// A file per owner is what makes "a reader draws only its own" possible: the reader resolves its own
/// file from its own session id and never opens another session's. What is left for the others is a
/// count ([elsewhere]), which carries no name and no text.
pub fn progress_dir() -> std::path::PathBuf { data_dir().join("tool-progress") }

/// The file name for an owner (a session id): every byte outside `A-Za-z0-9._-` percent-encoded, so
/// two owners cannot collide onto one file and the name is safe on every filesystem.
///
/// `lua/core/tool_progress.lua`'s `M.key` computes the same key: the host writes the file, the CLI
/// reads it, and `scripts/test-tool-progress.lua` pins the two implementations against one table.
///
/// `None` for an empty owner (a call nobody can claim is drawn by nobody - unknown is not yes) and for
/// a key too long for a file name: a truncated key would silently share a row with another owner, so a
/// key that does not fit publishes nothing instead.
pub fn owner_key(owner: &str) -> Option<String> {
    if owner.is_empty() { return None; }
    let mut key = String::with_capacity(owner.len());
    for byte in owner.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-') {
            key.push(byte as char);
        } else {
            key.push_str(&format!("%{byte:02X}"));
        }
    }
    if key.len() > 120 { return None; }
    Some(key)
}

/// `<data>/tool-progress/<key>.json` for the owning session, or `None` when it has no usable key.
pub fn progress_path(owner: &str) -> Option<std::path::PathBuf> {
    owner_key(owner).map(|key| progress_dir().join(format!("{key}.json")))
}

/// The one line a reader draws for work that is **not** its own: a count, and nothing else.
///
/// No tool name, no session id, no line of anybody's output. The aggregate exists so a reader can tell

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn no_secrets() -> Vec<String> { Vec::new() }

    #[test]
    fn the_live_file_draws_the_same_row_as_the_process() {
        let mut tracker = Tracker::new("bash", 1000.0);
        tracker.observe("  45%|#####     | 45.0/100.0 [00:03<00:04]\n", 1002.0);
        let facts = tracker.facts(1003.0, &no_secrets());
        assert_eq!(facts["state"], "running");
        assert_eq!(facts["tool"], "bash");
        let row = row_from_facts(&facts, 1003.0, &no_secrets()).expect("a row");
        assert_eq!(row, tracker.row(1003.0, &no_secrets()).unwrap(), "one decision, two renderers");
    }

    #[test]
    fn a_stale_or_finished_or_young_live_file_is_no_row() {
        let running = json!({"state":"running","tool":"bash","started_at":100.0,"at":200.0,
            "last_output_at":199.0,"detail":{"kind":"text","text":"compiling x"}});
        assert!(row_from_facts(&running, 205.0, &no_secrets()).is_some());
        assert!(row_from_facts(&running, 200.0 + FRESH + 1.0, &no_secrets()).is_none(), "a node that died mid-call");
        let mut done = running.clone();
        done["state"] = json!("done");
        assert!(row_from_facts(&done, 205.0, &no_secrets()).is_none(), "a settled call has no row");
        let young = json!({"state":"running","tool":"bash","started_at":204.0,"at":205.0,"last_output_at":205.0});
        assert!(row_from_facts(&young, 205.0, &no_secrets()).is_none(), "under two seconds: no row");
        assert!(row_from_facts(&json!({}), 205.0, &no_secrets()).is_none());
        // The stall rule applies to the file too.
        let quiet = json!({"state":"running","tool":"bash","started_at":0.0,"at":400.0,"last_output_at":0.0});
        let row = row_from_facts(&quiet, 400.0, &no_secrets()).unwrap();
        assert!(row.stalled);
        assert!(row.text.ends_with("no output for 6m40s"), "{}", row.text);
    }

    #[test]
    fn the_live_files_live_where_the_build_loader_does() {
        // The three tiers of scripts/lib/build-status.sh, in the order they win. Not asserted against
        // the process environment: this crate is also used from a node whose env it must not mutate.
        assert!(progress_dir().ends_with("tool-progress"));
        assert!(progress_path("s-1").expect("a key").ends_with("tool-progress/s-1.json"));
    }

    // ---- one file per session (session isolation, finding 1) -----------------------------------
    #[test]
    fn an_owners_key_is_its_session_id_and_two_sessions_never_share_a_file() {
        // A session id is a uuid: the key is the id itself, so the file is readable by a person
        // looking at the directory.
        assert_eq!(owner_key("3f9a1c2e-0b7d-4e51-9a3c-1d2b3c4d5e6f").as_deref(),
            Some("3f9a1c2e-0b7d-4e51-9a3c-1d2b3c4d5e6f"));
        // An owner with a separator in it cannot escape the directory, and cannot look like another.
        assert_eq!(owner_key("worker:7").as_deref(), Some("worker%3A7"));
        assert_eq!(owner_key("peer/work").as_deref(), Some("peer%2Fwork"));
        assert_eq!(owner_key("a b").as_deref(), Some("a%20b"));
        assert_ne!(owner_key("a/b"), owner_key("a_b"), "two owners, two files");
        // An empty owner is nobody's row, and a key too long for a file name is refused rather than
        // truncated onto another owner's name.
        assert_eq!(owner_key(""), None);
        assert_eq!(progress_path(""), None);
        assert_eq!(owner_key(&"s".repeat(121)), None);
        assert!(owner_key(&"s".repeat(120)).is_some());
        assert_ne!(progress_path("s-1"), progress_path("s-2"));
    }

    #[test]
    fn the_aggregate_is_a_count_with_no_name_and_no_text() {
        assert_eq!(elsewhere(1), "node: 1 op elsewhere");
        assert_eq!(elsewhere(3), "node: 3 ops elsewhere");
        // What the aggregate must never be: a tool name, a session id, a line of output.
        let line = elsewhere(2);
        assert!(!line.contains("bash") && !line.contains('\u{27f3}'));
    }
}

// ---------------------------------------------------------------------------------------------------
// The store: what a running call publishes for its own session's reader, and what removes it.
// MOVED OUT OF `wa-term`: the node publishes these facts (its own ticker) and the renderer reads them,
// so the file is this crate's business and neither side needs the drawing crate for it.

pub fn publish(owner: &str, facts: &Value) -> std::io::Result<()> {
    let Some(path) = progress_path(owner) else {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "tool_progress_owner_required"));
    };
    if let Some(dir) = path.parent() { std::fs::create_dir_all(dir)?; }
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, serde_json::to_vec(facts)?)?;
    std::fs::rename(&temporary, &path)
}

pub fn finish(owner: &str) {
    if let Some(path) = progress_path(owner) {
        let _ = std::fs::remove_file(path);
    }
}

