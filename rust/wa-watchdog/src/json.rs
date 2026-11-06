//! The smallest JSON this crate needs, with no crate: write a flat object, and read ONE top-level field.
//!
//! Both halves exist for a specific reader. The records the watchdog leaves on disk (`status.json`,
//! swap requests and results) are read by shell scripts and by a human, so they are written as real JSON
//! and every string goes through [`escape`] - a hand-formatted record with an unescaped path is the exact
//! class of bug that makes `sed`-based record readers lie. The values the watchdog *reads* are the ones
//! `/health` publishes and the requests it is handed, so [`field`] resolves a key at the TOP level only:
//! a nested `"ok"` (a subagent's, a run's) must never be mistaken for the node's.

/// One value of a written object. Kept deliberately narrow: the watchdog writes numbers, booleans,
/// strings and `null`, and nothing else.
pub enum Json {
    Str(String),
    Int(i64),
    UInt(u64),
    Bool(bool),
    Null,
    /// Already-serialized JSON (a nested object this module wrote itself).
    Raw(String),
}

impl From<&str> for Json {
    fn from(value: &str) -> Self {
        Json::Str(value.to_string())
    }
}

impl From<std::path::PathBuf> for Json {
    fn from(value: std::path::PathBuf) -> Self {
        Json::Str(value.display().to_string())
    }
}

impl From<&std::path::PathBuf> for Json {
    fn from(value: &std::path::PathBuf) -> Self {
        Json::Str(value.display().to_string())
    }
}

impl From<&std::path::Path> for Json {
    fn from(value: &std::path::Path) -> Self {
        Json::Str(value.display().to_string())
    }
}

impl From<String> for Json {
    fn from(value: String) -> Self {
        Json::Str(value)
    }
}

impl From<u64> for Json {
    fn from(value: u64) -> Self {
        Json::UInt(value)
    }
}

impl From<u16> for Json {
    fn from(value: u16) -> Self {
        Json::UInt(value as u64)
    }
}

impl From<u32> for Json {
    fn from(value: u32) -> Self {
        Json::UInt(value as u64)
    }
}

impl From<i64> for Json {
    fn from(value: i64) -> Self {
        Json::Int(value)
    }
}

impl From<bool> for Json {
    fn from(value: bool) -> Self {
        Json::Bool(value)
    }
}

fn render(value: &Json) -> String {
    match value {
        Json::Str(text) => quote(text),
        Json::Int(number) => number.to_string(),
        Json::UInt(number) => number.to_string(),
        Json::Bool(flag) => flag.to_string(),
        Json::Null => "null".to_string(),
        Json::Raw(text) => text.clone(),
    }
}

/// A JSON string literal, including the quotes. Escapes everything RFC 8259 requires plus the two
/// characters (`<`, DEL) that make a record hard to read in a terminal.
pub fn quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            ch if (ch as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out.push('"');
    out
}

/// A flat JSON object, keys in the order given (readability beats re-sorting; nothing here is compared
/// byte-for-byte).
pub fn object(pairs: &[(&str, Json)]) -> String {
    let body: Vec<String> = pairs.iter().map(|(key, value)| format!("{}:{}", quote(key), render(value))).collect();
    format!("{{{}}}", body.join(","))
}

fn skip_ws(bytes: &[u8], index: &mut usize) {
    while *index < bytes.len() && matches!(bytes[*index], b' ' | b'\t' | b'\n' | b'\r') {
        *index += 1;
    }
}

/// Skip one complete JSON value starting at `*index`, leaving `*index` just past it.
fn skip_value(bytes: &[u8], index: &mut usize) -> Option<()> {
    skip_ws(bytes, index);
    match bytes.get(*index)? {
        b'"' => {
            *index += 1;
            while *index < bytes.len() {
                match bytes[*index] {
                    b'\\' => *index += 2,
                    b'"' => {
                        *index += 1;
                        return Some(());
                    }
                    _ => *index += 1,
                }
            }
            None
        }
        b'{' | b'[' => {
            let close = if bytes[*index] == b'{' { b'}' } else { b']' };
            let mut depth = 0usize;
            while *index < bytes.len() {
                match bytes[*index] {
                    b'"' => {
                        skip_value(bytes, index)?;
                        continue;
                    }
                    b'{' | b'[' => depth += 1,
                    b'}' | b']' => {
                        depth -= 1;
                        if depth == 0 {
                            *index += 1;
                            // The browser/none case: mismatched closers are a parse failure, not a guess.
                            return if bytes[*index - 1] == close { Some(()) } else { None };
                        }
                    }
                    _ => {}
                }
                *index += 1;
            }
            None
        }
        _ => {
            let start = *index;
            while *index < bytes.len() && !matches!(bytes[*index], b',' | b'}' | b']' | b' ' | b'\t' | b'\n' | b'\r') {
                *index += 1;
            }
            if *index == start {
                None
            } else {
                Some(())
            }
        }
    }
}

/// The raw slice of the value of a TOP-LEVEL field, or `None` when the text is not an object or the key is
/// absent. Nested keys are never returned: `/health` carries many objects, and one of them having `ok` is
/// not the node saying it is well.
pub fn field<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    let bytes = text.as_bytes();
    let mut index = 0usize;
    skip_ws(bytes, &mut index);
    if bytes.get(index) != Some(&b'{') {
        return None;
    }
    index += 1;
    loop {
        skip_ws(bytes, &mut index);
        match *bytes.get(index)? {
            b'}' => return None,
            b'"' => {
                let start = index;
                skip_value(bytes, &mut index)?;
                let name = unquote(&text[start..index])?;
                skip_ws(bytes, &mut index);
                if bytes.get(index) != Some(&b':') {
                    return None;
                }
                index += 1;
                skip_ws(bytes, &mut index);
                let value_start = index;
                skip_value(bytes, &mut index)?;
                if name == key {
                    return Some(&text[value_start..index]);
                }
                skip_ws(bytes, &mut index);
                match *bytes.get(index)? {
                    b',' => index += 1,
                    b'}' => return None,
                    _ => return None,
                }
            }
            _ => return None,
        }
    }
}

/// A string field's decoded value.
pub fn field_str(text: &str, key: &str) -> Option<String> {
    unquote(field(text, key)?)
}

/// A boolean field's value; a non-boolean value is `None`, never a guess.
pub fn field_bool(text: &str, key: &str) -> Option<bool> {
    match field(text, key)?.trim() {
        "true" => Some(true),
        "false" => Some(false),
        _ => None,
    }
}

/// A non-negative integer field's value.
pub fn field_u64(text: &str, key: &str) -> Option<u64> {
    field(text, key)?.trim().parse().ok()
}

/// Decode a JSON string literal (with quotes) into its text. Not a general parser: exactly the escapes
/// [`quote`] produces, plus `\uXXXX` for the control range.
pub fn unquote(literal: &str) -> Option<String> {
    let literal = literal.trim();
    let inner = literal.strip_prefix('"')?.strip_suffix('"')?;
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(ch) = chars.next() {
        if ch != '\\' {
            out.push(ch);
            continue;
        }
        match chars.next()? {
            '"' => out.push('"'),
            '\\' => out.push('\\'),
            '/' => out.push('/'),
            'n' => out.push('\n'),
            'r' => out.push('\r'),
            't' => out.push('\t'),
            'b' => out.push('\u{8}'),
            'f' => out.push('\u{c}'),
            'u' => {
                let hex: String = (0..4).filter_map(|_| chars.next()).collect();
                let code = u32::from_str_radix(&hex, 16).ok()?;
                out.push(char::from_u32(code)?);
            }
            _ => return None,
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_written_object_round_trips_through_the_reader() {
        let text = object(&[
            ("id", "swap-1".into()),
            ("ok", true.into()),
            ("port", 8799u16.into()),
            ("missing", Json::Null),
            ("binary", Json::from("/tmp/a \"quoted\" \\ path/wa".to_string())),
        ]);
        assert_eq!(field_str(&text, "id").as_deref(), Some("swap-1"));
        assert_eq!(field_bool(&text, "ok"), Some(true));
        assert_eq!(field_u64(&text, "port"), Some(8799));
        assert_eq!(field(&text, "missing"), Some("null"));
        assert_eq!(field_bool(&text, "missing"), None);
        assert_eq!(field_str(&text, "binary").as_deref(), Some("/tmp/a \"quoted\" \\ path/wa"));
        assert_eq!(field_str(&text, "absent"), None);
    }

    #[test]
    fn a_nested_key_is_not_a_top_level_key() {
        // The exact mistake that made `/health`-reading scripts lie: `ok` exists, but inside `subagents`.
        let text = r#"{"state":"idle","subagents":{"ok":false,"active":0},"ok":true}"#;
        assert_eq!(field_bool(text, "ok"), Some(true));
        let text = r#"{"subagents":{"ok":false,"active":0}}"#;
        assert_eq!(field_bool(text, "ok"), None);
        assert_eq!(field_u64(text, "active"), None);
    }

    #[test]
    fn braces_and_escapes_inside_strings_do_not_end_the_object() {
        let text = r#"{"note":"a } , { \"ok\": true","ok":false}"#;
        assert_eq!(field_bool(text, "ok"), Some(false));
        assert_eq!(field_str(text, "note").as_deref(), Some("a } , { \"ok\": true"));
    }

    #[test]
    fn arrays_are_skipped_whole() {
        let text = r#"{"runs":[{"id":1,"ok":true},[2,3]],"ok":true}"#;
        assert_eq!(field_bool(text, "ok"), Some(true));
    }

    #[test]
    fn not_an_object_is_not_a_field() {
        assert_eq!(field("[]", "ok"), None);
        assert_eq!(field("", "ok"), None);
        // A body cut off after the value still answers: a read that timed out mid-response is not a reason to
        // report a node as silent, and the field that did arrive is the node's own word.
        assert_eq!(field("{\"ok\":true", "ok"), Some("true"));
        // A body cut off inside the KEY answers nothing: a half-read name is not a name.
        assert_eq!(field("{\"o", "ok"), None);
    }

    #[test]
    fn control_characters_are_escaped() {
        let text = quote("a\nb\tc\u{1}d");
        assert_eq!(text, "\"a\\nb\\tc\\u0001d\"");
        assert_eq!(unquote(&text).as_deref(), Some("a\nb\tc\u{1}d"));
    }
}
