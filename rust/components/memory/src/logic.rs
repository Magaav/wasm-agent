//! The memory logic that is not SQL: term extraction for the FTS query, the two-pass recall
//! decision, the session state derivation and the retention decision.
//!
//! It lives apart from `lib.rs` because it is the part worth testing on its own, and because every
//! rule here is a copy of a rule in `lua/core/memory.lua` that the parity suite compares word for
//! word. Where a rule looks arbitrary, the comment says why the Lua one is arbitrary in exactly that
//! way: a "cleaner" rule here would be a difference the parity suite would report as a defect.

/// The ASCII punctuation `lua/core/memory.lua` splits terms on. Lua's `%p` is C `ispunct`, and C
/// `ispunct` counts `_` — so `foo_bar` is two terms in the native path and must be two here.
fn is_term_punctuation(c: char) -> bool {
    c.is_ascii_punctuation()
}

/// Terms of an FTS5 MATCH expression, quoted so arbitrary text cannot be read as FTS syntax, and
/// deduplicated on the lowercased term so a repeated word does not skew bm25.
///
/// A word is a run of anything that is not ASCII space or punctuation, so UTF-8 letters stay inside
/// it (`[%w_]+` was ASCII-only and cut "configuração" apart). The FTS tokenizer folds case and
/// diacritics on both sides, so the query word matches the indexed one. Quotes are punctuation, so a
/// term can never close its own quoting.
pub fn fts_terms(text: &str) -> Vec<String> {
    let mut terms: Vec<String> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    let mut current = String::new();
    for c in text.chars() {
        if c.is_ascii_whitespace() || is_term_punctuation(c) {
            if !current.is_empty() {
                push_term(&mut terms, &mut seen, std::mem::take(&mut current));
            }
        } else {
            current.push(c);
        }
    }
    if !current.is_empty() {
        push_term(&mut terms, &mut seen, current);
    }
    terms
}

fn push_term(terms: &mut Vec<String>, seen: &mut Vec<String>, term: String) {
    let key = term.to_ascii_lowercase();
    if seen.contains(&key) {
        return;
    }
    seen.push(key);
    terms.push(term);
}

fn quoted(terms: &[String]) -> String {
    terms.iter().map(|term| format!("\"{term}\"")).collect::<Vec<_>>().join(" AND ")
}

/// The AND expression a search starts from (`M.fts_query`).
pub fn fts_query(text: &str) -> String {
    quoted(&fts_terms(text))
}

/// The recall passes: all terms present first, then — only when that found nothing and the query had
/// more than one term — any term matching, minus the one-letter words that match nearly every row.
///
/// Returns the MATCH expressions to try, in order. Empty when the text holds no terms at all.
pub fn recall_passes(text: &str) -> Vec<String> {
    let terms = fts_terms(text);
    if terms.is_empty() {
        return Vec::new();
    }
    let mut passes = vec![quoted(&terms)];
    if terms.len() > 1 {
        // Lua compares `#term > 3` on the *quoted* term (`"a"` is 3 bytes, `"ab"` is 4), so a word
        // survives when it is at least two bytes long. Byte length, not characters: a two-byte
        // accented letter counts as one character and two bytes, and is kept.
        let wide: Vec<String> = terms.iter().filter(|term| term.len() >= 2).cloned().collect();
        if !wide.is_empty() {
            passes.push(wide.iter().map(|term| format!("\"{term}\"")).collect::<Vec<_>>().join(" OR "));
        }
    }
    passes
}

/// The derived state of a thread, from its last message (`classify` in `lua/core/memory.lua`).
///
/// `last` is (role, ok, phase, tool_calls-json). A thread that was cut off looks exactly like one
/// whose answer is still coming, so `unfinished` says both are possible and never claims a death.
pub fn classify(last: Option<&LastMessage>) -> &'static str {
    let Some(last) = last else { return "empty" };
    if last.role == "user" && last.phase.as_deref() == Some("bash") {
        return "answered";
    }
    if last.role == "assistant" {
        if last.ok == Some(0) {
            return "failed";
        }
        if last.phase.as_deref() == Some("commentary") {
            return "unfinished";
        }
        if tool_call_count(last.tool_calls.as_deref()) > 0 {
            return "unfinished";
        }
        return "answered";
    }
    "unfinished"
}

pub struct LastMessage {
    pub role: String,
    pub ok: Option<i64>,
    pub phase: Option<String>,
    pub tool_calls: Option<String>,
}

/// How many calls the step carried. The same decode the native path does: a string is JSON, a
/// missing or unreadable value is zero calls.
pub fn tool_call_count(tool_calls: Option<&str>) -> usize {
    let Some(raw) = tool_calls else { return 0 };
    match serde_json::from_str::<serde_json::Value>(raw) {
        Ok(serde_json::Value::Array(items)) => items.len(),
        _ => 0,
    }
}

/// Why the store refuses to retire originals: compaction, quiet and a replication acknowledgment are
/// not evidence that a recovery consumer released them (docs/MEMORY.md, "Retention").
pub const RETENTION_REFUSAL: &str = "retention_evidence_admission_required";

/// What a retention sweep may do. It returns the decision, never a deletion.
pub struct RetentionDecision {
    pub refused: Option<String>,
    pub eligible: u64,
}

/// The retention decision for `older_than_seconds`: rows a sweep *would* take if an admission
/// existed. Duplicate text is retired with the row it repeats; a soft-deleted memory is already
/// forgotten, so counting it changes nothing about what is preserved.
pub fn retention(now: f64, older_than_seconds: f64, forgotten_memories: u64) -> RetentionDecision {
    let _ = (now, older_than_seconds);
    RetentionDecision { refused: Some(RETENTION_REFUSAL.to_string()), eligible: forgotten_memories }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terms_fold_case_and_split_on_punctuation_including_underscore() {
        assert_eq!(fts_terms("Alpha beta ALPHA"), vec!["Alpha", "beta"]);
        // C `ispunct` counts `_`, so the native path splits an identifier; so does this one.
        assert_eq!(fts_terms("foo_bar"), vec!["foo", "bar"]);
        // Non-ASCII letters stay inside the term.
        assert_eq!(fts_terms("configuração"), vec!["configuração"]);
        // A quote cannot open a second quoting.
        assert_eq!(fts_query(r#"a"b"#), r#""a" AND "b""#);
    }

    #[test]
    fn recall_tries_all_terms_then_any_term_minus_one_letter_words() {
        assert_eq!(recall_passes(""), Vec::<String>::new());
        assert_eq!(recall_passes("one"), vec![r#""one""#]);
        let passes = recall_passes("a cafe open");
        assert_eq!(passes.len(), 2);
        assert_eq!(passes[0], r#""a" AND "cafe" AND "open""#);
        // "a" is one byte, so the quoted form is 3 bytes and the native filter drops it.
        assert_eq!(passes[1], r#""cafe" OR "open""#);
    }

    #[test]
    fn classify_matches_the_native_states() {
        let last = |role: &str, ok: Option<i64>, phase: Option<&str>, calls: Option<&str>| LastMessage {
            role: role.to_string(),
            ok,
            phase: phase.map(str::to_string),
            tool_calls: calls.map(str::to_string),
        };
        assert_eq!(classify(None), "empty");
        assert_eq!(classify(Some(&last("assistant", Some(1), None, Some("[]")))), "answered");
        assert_eq!(classify(Some(&last("assistant", Some(0), None, Some("[]")))), "failed");
        assert_eq!(classify(Some(&last("assistant", Some(1), Some("commentary"), None))), "unfinished");
        assert_eq!(
            classify(Some(&last("assistant", Some(1), None, Some(r#"[{"id":"1"}]"#)))),
            "unfinished"
        );
        assert_eq!(classify(Some(&last("user", Some(1), None, None))), "unfinished");
        assert_eq!(classify(Some(&last("user", Some(1), Some("bash"), None))), "answered");
        assert_eq!(classify(Some(&last("tool", Some(1), None, None))), "unfinished");
    }

    #[test]
    fn retention_never_retires_without_an_admission() {
        let decision = retention(1_700_000_000.0, 86_400.0, 3);
        assert_eq!(decision.refused.as_deref(), Some(RETENTION_REFUSAL));
        assert_eq!(decision.eligible, 3);
    }
}
