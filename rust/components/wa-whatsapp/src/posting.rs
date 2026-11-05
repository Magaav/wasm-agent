//! Posting policy: who may receive a transcript, how it is split and marked, and the pacing of
//! post-then-edit streaming. Pure logic (unit-tested natively); lib.rs does the sends.
//!
//! Safety: posting is OFF unless the configuration says `post_transcripts: true` AND the source
//! chat matches `post_allow`. The allowlist is the gate: `"own"` = the account's own chat (its
//! phone-number or LID user), an exact chat JID, or `"*"` (every chat: the cutover setting, B3).
//! An empty or missing allowlist posts nowhere.

pub const PART_RUNES: usize = 2500;
pub const HEADER: &str = "🤖 _Copiloto_";

#[derive(Clone, Debug, PartialEq)]
pub struct PostConfig {
    pub post: bool,
    pub allow: Vec<String>,
    /// Chats where posting is held (the Go connector's chat holds, carried over by configuration).
    pub held: Vec<String>,
    pub alerts: bool,
    pub stream_edits: bool,
    pub stream_min_seconds: u32,
    pub edit_interval_ms: i64,
}

impl PostConfig {
    pub fn from_json(v: &serde_json::Value) -> Self {
        let list = |k: &str| v[k].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect()).unwrap_or_default();
        PostConfig {
            post: v["post_transcripts"] == serde_json::json!(true),
            allow: list("post_allow"),
            held: list("held_chats"),
            alerts: v["alerts"] == serde_json::json!(true),
            stream_edits: v["stream_edits"] == serde_json::json!(true),
            stream_min_seconds: v["stream_min_seconds"].as_u64().unwrap_or(15).min(3600) as u32,
            edit_interval_ms: v["edit_interval_seconds"].as_u64().unwrap_or(5).clamp(2, 60) as i64 * 1000,
        }
    }

    /// May a transcript for `chat` be posted? `own_users` = the account's own user parts
    /// (phone number and LID), for the `"own"` entry.
    pub fn allowed(&self, chat: &str, own_users: &[String]) -> bool {
        if !self.post {
            return false;
        }
        let user = chat.split('@').next().unwrap_or("");
        let server = chat.split('@').nth(1).unwrap_or("");
        self.allow.iter().any(|entry| match entry.as_str() {
            "*" => true,
            "own" => server != "g.us" && !user.is_empty() && own_users.iter().any(|u| u == user),
            exact => exact == chat,
        })
    }

    pub fn held(&self, chat: &str) -> bool {
        self.held.iter().any(|c| c == chat)
    }

    /// Stream (post first, then edit) for a note this long?
    pub fn streams(&self, declared_seconds: u32) -> bool {
        self.stream_edits && declared_seconds >= self.stream_min_seconds
    }
}

/// Split into marked parts of at most 2500 characters, like the Go connector:
/// "🤖 _Copiloto_\n<text>" or "🤖 _Copiloto_ (i/n)\n<part>".
pub fn chunks(text: &str) -> Vec<String> {
    let runes: Vec<char> = text.chars().collect();
    let parts: Vec<String> = runes.chunks(PART_RUNES).map(|c| c.iter().collect()).collect();
    let n = parts.len();
    parts
        .into_iter()
        .enumerate()
        .map(|(i, p)| if n == 1 { format!("{HEADER}\n{p}") } else { format!("{HEADER} ({}/{n})\n{p}", i + 1) })
        .collect()
}

/// The in-progress body while streaming: the text so far (capped to one part), marked unfinished.
pub fn partial(text: &str) -> String {
    let capped: String = text.chars().take(PART_RUNES).collect();
    format!("{HEADER} ⏳\n{capped} …")
}

/// At most one edit per interval; the final edit always goes.
#[derive(Debug)]
pub struct EditPacer {
    interval_ms: i64,
    last_ms: Option<i64>,
    pub edits: u32,
}

impl EditPacer {
    pub fn new(interval_ms: i64) -> Self {
        EditPacer { interval_ms, last_ms: None, edits: 0 }
    }
    /// Is an update allowed at `now`? The first post is always allowed.
    pub fn ready(&self, now: i64) -> bool {
        self.last_ms.is_none_or(|last| now - last >= self.interval_ms)
    }
    pub fn mark(&mut self, now: i64, is_edit: bool) {
        self.last_ms = Some(now);
        if is_edit {
            self.edits += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(v: serde_json::Value) -> PostConfig {
        PostConfig::from_json(&v)
    }

    #[test]
    fn posting_off_by_default_and_allowlist_is_the_gate() {
        let own = vec!["5519994939204".to_string(), "72103978127547".to_string()];
        assert!(!cfg(serde_json::json!({})).allowed("72103978127547@lid", &own));
        assert!(!cfg(serde_json::json!({"post_transcripts": true})).allowed("72103978127547@lid", &own), "no allowlist = nowhere");
        let c = cfg(serde_json::json!({"post_transcripts": true, "post_allow": ["own"]}));
        assert!(c.allowed("72103978127547@lid", &own));
        assert!(c.allowed("5519994939204@s.whatsapp.net", &own));
        assert!(!c.allowed("5511999999999@s.whatsapp.net", &own));
        assert!(!c.allowed("72103978127547@g.us", &own), "a group is never the own chat");
        assert!(!cfg(serde_json::json!({"post_transcripts": false, "post_allow": ["*"]})).allowed("x@g.us", &own));
        assert!(cfg(serde_json::json!({"post_transcripts": true, "post_allow": ["*"]})).allowed("x@g.us", &own));
        assert!(cfg(serde_json::json!({"post_transcripts": true, "post_allow": ["1@g.us"]})).allowed("1@g.us", &own));
    }

    #[test]
    fn chunks_match_the_go_format() {
        assert_eq!(chunks("olá"), vec!["🤖 _Copiloto_\nolá".to_string()]);
        let long = "a".repeat(5001);
        let parts = chunks(&long);
        assert_eq!(parts.len(), 3);
        assert!(parts[0].starts_with("🤖 _Copiloto_ (1/3)\n") && parts[2].starts_with("🤖 _Copiloto_ (3/3)\na"));
        let accented = "é".repeat(2500);
        assert_eq!(chunks(&accented).len(), 1, "split on characters, not bytes");
    }

    #[test]
    fn streaming_threshold_and_pacing() {
        let c = cfg(serde_json::json!({"stream_edits": true}));
        assert!(!c.streams(14) && c.streams(15));
        assert!(!cfg(serde_json::json!({})).streams(600), "off by default");
        let mut p = EditPacer::new(c.edit_interval_ms);
        assert!(p.ready(0));
        p.mark(0, false);
        assert!(!p.ready(4_999));
        assert!(p.ready(5_000));
        p.mark(5_000, true);
        assert_eq!(p.edits, 1);
        assert!(partial("abc").ends_with("abc …") && partial("abc").starts_with("🤖 _Copiloto_ ⏳"));
    }
}
