//! The redaction rules the tree already had, in Rust, applied at the sink's edge.
//!
//! `lua/core/redact.lua` is the one place a secret is masked before it leaves the process, and its
//! comment says why: per-call-site care is how secrets leak. The sink is a new boundary (records go
//! to a file and, optionally, over HTTP to a collector), so it uses the *same* rules rather than a
//! second idea of what a credential looks like:
//!
//! | rule | shape |
//! | --- | --- |
//! | value patterns | `sk-…`, `ghp_…`/`github_pat_…`/`glpat-…`/`xox[baprs]-…`/`AKIA…`/`AIza…`, JWTs (`eyJ….….…`) |
//! | named assignment | `NAME = value` / `NAME: "value"` where `NAME` looks like a secret |
//! | bearer | `Bearer <token>` |
//!
//! [`mask`] keeps three characters and the last four (`sk-...7f2a`) so an operator can tell *which*
//! key was involved without being able to use it; a value shorter than twelve characters becomes
//! `<redacted>`. [`text`] runs the rules repeatedly until the string stops changing, because a
//! replacement can expose a neighbouring pattern and because masking is idempotent.
//!
//! The stronger guarantee sits above this module: a [`crate::Record`] has no message-text field at
//! all. Text only ever arrives as an attribute value, and [`crate::Attr::from_text`] turns anything
//! that is not already an id or a count into a digest — and anything that *is* secret-shaped into
//! nothing. So these rules are the second line, applied to the strings that do leave the process:
//! a batch's declared `schema`/`topic`, and an exporter's error text.

/// Shortest value that keeps its shape when masked. Below this, "which key" is not guessable from
/// four characters, so the whole value goes.
pub const MASK_FLOOR: usize = 12;

/// Characters the mask keeps: three from the front, four from the back.
pub fn mask(value: &str) -> String {
    let chars: Vec<char> = value.chars().collect();
    if chars.len() < MASK_FLOOR {
        return "<redacted>".to_string();
    }
    let head: String = chars[..3].iter().collect();
    let tail: String = chars[chars.len() - 4..].iter().collect();
    format!("{head}...{tail}")
}

fn is_token(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-'
}

fn is_value_end(byte: u8) -> bool {
    matches!(byte, b'"' | b'\'' | b',' | b'}' | b' ' | b'\t' | b'\n' | b'\r')
}

/// Does the *whole* string look like one credential? Used where a value either is a name or is not
/// allowed to leave at all; a substring match would refuse ordinary prose that merely mentions a key.
pub fn is_secret_like(value: &str) -> bool {
    let bytes = value.as_bytes();
    if let Some((start, _)) = value_prefix(bytes, 0) {
        if start == 0 {
            return true;
        }
    }
    if bytes.starts_with(b"eyJ") && redact_jwt(value.as_bytes(), 0).is_some() {
        return true;
    }
    // `NAME=<value>` where the value is not already masked and the assignment is the whole string.
    if let Some(index) = value.find(['=', ':']) {
        if let Some((value_start, value_end)) = named_assignment(bytes, index) {
            if value_end == bytes.len() {
                let assigned = &value[value_start..value_end];
                return assigned != "<redacted>" && !assigned.contains("...");
            }
        }
    }
    false
}

/// One of the credential prefixes the Lua rules know, at `index`; returns the prefix length and the
/// end of the token it starts.
fn value_prefix(bytes: &[u8], index: usize) -> Option<(usize, usize)> {
    const PREFIXES: [&[u8]; 11] = [
        b"sk-",
        b"ghp_",
        b"github_pat_",
        b"glpat-",
        b"xoxa-",
        b"xoxb-",
        b"xoxp-",
        b"xoxr-",
        b"xoxs-",
        b"AKIA",
        b"AIza",
    ];
    for prefix in PREFIXES {
        if bytes[index..].starts_with(prefix) {
            let mut end = index + prefix.len();
            while end < bytes.len() && is_token(bytes[end]) {
                end += 1;
            }
            if end > index + prefix.len() {
                return Some((index, end));
            }
        }
    }
    None
}

/// A JWT starting at `index`: three dot-separated token runs, the first beginning `eyJ`.
fn redact_jwt(bytes: &[u8], index: usize) -> Option<usize> {
    if !bytes[index..].starts_with(b"eyJ") {
        return None;
    }
    let mut cursor = index;
    for part in 0..3 {
        let start = cursor;
        while cursor < bytes.len() && is_token(bytes[cursor]) {
            cursor += 1;
        }
        if cursor == start {
            return None;
        }
        if part < 2 {
            if cursor >= bytes.len() || bytes[cursor] != b'.' {
                return None;
            }
            cursor += 1;
        }
    }
    Some(cursor)
}

/// `NAME` (secret-shaped) then optional whitespace then `=`/`:` then optional whitespace then an
/// optional quote, with the `=`/`:` at `index`. Returns the byte range of the *value*.
fn named_assignment(bytes: &[u8], index: usize) -> Option<(usize, usize)> {
    if bytes.get(index) != Some(&b'=') && bytes.get(index) != Some(&b':') {
        return None;
    }
    // Backwards: optional whitespace, optional `"`, then the name.
    let mut cursor = index;
    while cursor > 0 && matches!(bytes[cursor - 1], b' ' | b'\t') {
        cursor -= 1;
    }
    if cursor > 0 && bytes[cursor - 1] == b'"' {
        cursor -= 1;
    }
    let mut start = cursor;
    while start > 0 && (is_token(bytes[start - 1]) || bytes[start - 1] == b'.') {
        start -= 1;
    }
    if start == cursor {
        return None;
    }
    let name = String::from_utf8_lossy(&bytes[start..cursor]).to_ascii_uppercase();
    const WORDS: [&str; 9] = [
        "API_KEY",
        "APIKEY",
        "_KEY",
        "KEY",
        "TOKEN",
        "SECRET",
        "PASSWORD",
        "PASSWD",
        "CREDENTIAL",
    ];
    let auth = !name.is_empty() && name.contains("AUTH");
    if !auth && !WORDS.iter().any(|word| name.contains(word)) {
        return None;
    }
    // Forwards: whitespace, optional quote, then the value.
    let mut value_start = index + 1;
    while value_start < bytes.len() && matches!(bytes[value_start], b' ' | b'\t') {
        value_start += 1;
    }
    if value_start < bytes.len() && (bytes[value_start] == b'"' || bytes[value_start] == b'\'') {
        value_start += 1;
    }
    let mut value_end = value_start;
    while value_end < bytes.len() && !is_value_end(bytes[value_end]) {
        value_end += 1;
    }
    if value_end == value_start {
        return None;
    }
    // `Authorization: Bearer <token>` is the bearer rule's case: masking the word "Bearer" here would
    // leave the token itself in the clear.
    if bytes[value_start..value_end].eq_ignore_ascii_case(b"bearer") {
        return None;
    }
    Some((value_start, value_end))
}

/// The Lua `M.text` rules, ported: up to three passes, stopping early once the string is stable.
pub fn text(input: &str) -> String {
    let mut current = input.to_string();
    for _ in 0..3 {
        let before = current.clone();
        current = one_pass(&current);
        if current == before {
            break;
        }
    }
    current
}

fn one_pass(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if let Some((_, end)) = value_prefix(bytes, index) {
            out.extend_from_slice(mask(&input[index..end]).as_bytes());
            index = end;
            continue;
        }
        if let Some(end) = redact_jwt(bytes, index) {
            out.extend_from_slice(mask(&input[index..end]).as_bytes());
            index = end;
            continue;
        }
        if (bytes[index] == b'B' || bytes[index] == b'b')
            && bytes[index..].starts_with(if bytes[index] == b'B' { b"Bearer" } else { b"bearer" })
        {
            let mut cursor = index + 6;
            let gap = cursor;
            while cursor < bytes.len() && matches!(bytes[cursor], b' ' | b'\t') {
                cursor += 1;
            }
            if cursor > gap {
                let start = cursor;
                while cursor < bytes.len() && is_token(bytes[cursor]) {
                    cursor += 1;
                }
                if cursor > start {
                    let token = &input[start..cursor];
                    out.extend_from_slice(&bytes[index..start]);
                    if token == "<redacted>" || token.contains("...") {
                        out.extend_from_slice(token.as_bytes());
                    } else {
                        out.extend_from_slice(mask(token).as_bytes());
                    }
                    index = cursor;
                    continue;
                }
            }
        }
        if let Some((value_start, value_end)) = named_assignment(bytes, index) {
            let value = &input[value_start..value_end];
            out.extend_from_slice(&bytes[index..value_start]);
            if value == "<redacted>" || value.contains("...") {
                out.extend_from_slice(value.as_bytes());
            } else {
                out.extend_from_slice(mask(value).as_bytes());
            }
            index = value_end;
            continue;
        }
        out.push(bytes[index]);
        index += 1;
    }
    match String::from_utf8(out) {
        Ok(text) => text,
        Err(error) => String::from_utf8_lossy(error.as_bytes()).into_owned(),
    }
}

/// A short, mask-shaped reason: the exporter's error text, capped, with the rules applied. Error
/// text is where a URL with a token in it would otherwise reach a log line.
pub fn reason(input: &str, cap: usize) -> String {
    let text = text(input);
    let trimmed: String = text.chars().take(cap).collect();
    if trimmed.len() < text.len() {
        format!("{trimmed}…")
    } else {
        trimmed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mask_keeps_shape_above_the_floor() {
        assert_eq!(mask("sk-abcdefghijkl7f2a"), "sk-...7f2a");
        assert_eq!(mask("short"), "<redacted>");
        assert_eq!(mask(""), "<redacted>");
    }

    #[test]
    fn value_patterns_are_masked() {
        let out = text("key sk-abc123def456ghi789 used");
        assert!(out.contains("sk-..."), "{out}");
        assert!(!out.contains("abc123def456"), "{out}");
        let out = text("token ghp_0123456789abcdef and AKIAIOSFODNN7EXAMPLE");
        assert!(!out.contains("0123456789abcdef"), "{out}");
        assert!(!out.contains("IOSFODNN7EXAMPLE"), "{out}");
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N";
        let out = text(&format!("authorization {jwt}"));
        assert!(!out.contains("dozjgNryP4J3"), "{out}");
    }

    #[test]
    fn named_assignments_are_masked_including_quotes_and_colons() {
        for line in [
            "API_KEY=supersecretvalue123",
            "MY_SECRET_TOKEN: \"another-secret-value\"",
            "password = hunter2hunter2",
            "auth_credential=abcdefghijklmn",
        ] {
            let out = text(line);
            assert!(out.contains("...") || out.contains("<redacted>"), "{line} -> {out}");
            for word in ["supersecretvalue123", "another-secret-value", "hunter2hunter2", "abcdefghijklmn"] {
                assert!(!out.contains(word), "{line} -> {out}");
            }
        }
    }

    #[test]
    fn bearer_is_masked() {
        let out = text("Authorization: Bearer abcdefghijklmnop");
        assert!(!out.contains("abcdefghijklmnop"), "{out}");
        assert!(out.contains("Bearer "), "{out}");
    }

    #[test]
    fn redaction_is_idempotent_and_ordinary_prose_survives() {
        let once = text("API_KEY=supersecretvalue123 and Bearer abcdefghijklmnop, ok");
        let twice = text(&once);
        assert_eq!(once, twice);
        let plain = text("component wa-host op transcribe status ok");
        assert_eq!(plain, "component wa-host op transcribe status ok");
    }

    #[test]
    fn is_secret_like_only_for_whole_credentials() {
        assert!(is_secret_like("sk-abcdefghijkl7f2a"));
        assert!(is_secret_like("glpat-abcdefghijklmnop"));
        assert!(is_secret_like("API_KEY=supersecretvalue123"));
        assert!(!is_secret_like("hello sk-abc is a prefix"));
        assert!(!is_secret_like("wa-host"));
        assert!(!is_secret_like("API_KEY=<redacted>"));
        assert!(!is_secret_like("API_KEY=sk-...7f2a"));
    }

    #[test]
    fn reason_caps_and_masks() {
        let long = "x".repeat(400);
        let out = reason(&format!("token=supersecretvalue123 {long}"), 32);
        assert!(out.chars().count() <= 33, "{}", out.chars().count());
        assert!(!out.contains("supersecretvalue123"), "{out}");
    }
}
