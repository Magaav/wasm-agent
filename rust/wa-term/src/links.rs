//! The one URL detector: which run of characters in a line of text is a link.
//!
//! Two surfaces need the same answer, and until now each had its own. The renderer
//! (lua/core/markdown.lua) underlined a bare URL to say "this is a link"; the console (host.rs,
//! url_at) decided which link the pointer was on so a click could copy it. The rules drifted - the
//! Lua pattern kept a trailing dot and the Rust one dropped it - so a link could be underlined in one
//! place and copy a different string when it was clicked. This module is that answer, and both call
//! it:
//!
//! * host.rs asks [at] for the URL under a screen column (a click on a link);
//! * host.link_span(text) answers [first] to Lua, which is what markdown.lua styles.
//!
//! The rule, in words: https:// or http:// followed by at least one character that is not whitespace
//! and not one of < > " ' (backtick) | ) ]; a trailing . , ; : ! ? is punctuation and not part of the
//! link. Nothing else is inspected - a percent-escape, a +, a #fragment and a query with & all belong
//! to the URL, and a name that merely contains http:// mid-word is a link too (which is what a model
//! pasting a URL into a sentence produces).
//!
//! Character indices, not bytes: the console counts cells and the renderer slices bytes, so [spans]
//! answers in chars and the callers translate. That is the only piece of knowledge the two sides
//! share without agreeing on it twice, and it is why the boundary rules are here and nowhere else.

/// The characters a URL is cut at: whitespace ends it, and so does the punctuation that wraps a link
/// in prose or in a terminal frame (<https://x> in markdown, a box's bar on screen).
fn ends_link(ch: char) -> bool {
    ch.is_whitespace() || matches!(ch, '<' | '>' | '"' | '\'' | '\u{60}' | '\u{2502}' | ')' | ']')
}

/// The characters dropped from the end of a link, one at a time: a sentence's full stop, and the
/// punctuation that follows a link inside parentheses or a clause.
fn trailing(ch: char) -> bool {
    matches!(ch, '.' | ',' | ';' | ':' | '!' | '?')
}

const SCHEMES: [&str; 2] = ["https://", "http://"];

/// Every bare URL in text, as char ranges [start, end) in order. A scheme with nothing after it
/// (https:// alone) is not a link.
pub fn spans(text: &str) -> Vec<(usize, usize)> {
    let chars: Vec<char> = text.chars().collect();
    let mut out: Vec<(usize, usize)> = Vec::new();
    let mut at = 0usize;
    while at < chars.len() {
        let length = SCHEMES.iter().map(|scheme| scheme.chars().count())
            .find(|length| at + length <= chars.len()
                && SCHEMES.iter().any(|scheme| chars[at..at + *length].iter().copied().eq(scheme.chars())));
        let Some(scheme) = length else {
            at += 1;
            continue;
        };
        let mut end = at + scheme;
        while end < chars.len() && !ends_link(chars[end]) { end += 1; }
        while end > at + scheme && trailing(chars[end - 1]) { end -= 1; }
        if end > at + scheme {
            out.push((at, end));
            at = end;
        } else {
            at += scheme;
        }
    }
    out
}

/// The first bare URL in text, as a char range [start, end).
pub fn first(text: &str) -> Option<(usize, usize)> {
    spans(text).into_iter().next()
}

/// The run of text a char range covers.
pub fn text_of(text: &str, span: (usize, usize)) -> String {
    text.chars().skip(span.0).take(span.1.saturating_sub(span.0)).collect()
}

/// The first bare URL in text as byte offsets [start, end), which is what Lua string positions are.
pub fn first_bytes(text: &str) -> Option<(usize, usize)> {
    let span = first(text)?;
    let start = text.char_indices().nth(span.0).map(|(byte, _)| byte)?;
    let end = text.char_indices().nth(span.1).map(|(byte, _)| byte).unwrap_or(text.len());
    Some((start, end))
}

/// The char index of the character drawn at column col (1-based, in terminal cells) of line. A wide
/// character owns both of its cells; a column past the end of the line has none.
pub fn char_at_cell(line: &str, col: usize) -> Option<usize> {
    let mut used = 0usize;
    for (index, ch) in line.chars().enumerate() {
        let width = crate::terminal_editor::cell_width_of(ch).max(1);
        if col > used && col <= used + width {
            return Some(index);
        }
        used += width;
    }
    None
}

/// The URL under column col (1-based, in terminal cells) of a plain screen row, or None.
pub fn at(line: &str, col: usize) -> Option<String> {
    let index = char_at_cell(line, col)?;
    spans(line).into_iter().find(|(start, end)| index >= *start && index < *end)
        .map(|span| text_of(line, span))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The column (1-based, in cells) of the character at byte offset in an ASCII line.
    fn column(line: &str, needle: &str) -> usize {
        line.find(needle).expect("needle") + 1
    }

    #[test]
    fn a_url_in_a_sentence_is_the_url_and_not_the_full_stop() {
        let line = "see https://example.com/a?b=1&c=2. and then";
        assert_eq!(spans(line), vec![(4, 33)]);
        assert_eq!(at(line, column(line, "https")).as_deref(), Some("https://example.com/a?b=1&c=2"));
        assert_eq!(at(line, column(line, "c=2") + 2).as_deref(), Some("https://example.com/a?b=1&c=2"),
            "the last character of the link is inside it");
        assert_eq!(at(line, column(line, ". and")).as_deref(), None, "the full stop is not part of the link");
    }

    #[test]
    fn a_url_wrapped_in_brackets_loses_the_brackets() {
        let line = "read <https://example.com/x> now";
        assert_eq!(at(line, column(line, "https")).as_deref(), Some("https://example.com/x"));
        assert_eq!(at(line, column(line, "x>")).as_deref(), Some("https://example.com/x"), "the last character is inside");
        assert_eq!(at(line, column(line, "> now")).as_deref(), None, "the closing bracket is not");
        assert_eq!(spans("a (https://example.com/y) b"), vec![(3, 24)]);
    }

    #[test]
    fn two_links_are_two_spans_and_the_column_picks_one() {
        let line = "https://a.example https://b.example";
        assert_eq!(spans(line), vec![(0, 17), (18, 35)]);
        assert_eq!(at(line, column(line, "https")).as_deref(), Some("https://a.example"));
        assert_eq!(at(line, column(line, "https://b")).as_deref(), Some("https://b.example"));
        assert_eq!(at(line, column(line, "b.example") + 2).as_deref(), Some("https://b.example"),
            "the last character of the second link is inside it");
        assert_eq!(at(line, 18), None, "the space between them is no link");
    }

    #[test]
    fn http_is_a_link_and_a_bare_scheme_is_not() {
        assert_eq!(spans("http://x").len(), 1);
        assert_eq!(spans("https://"), Vec::new());
        assert_eq!(spans("no link here"), Vec::new());
        assert_eq!(first("https://only.example"), Some((0, 20)));
    }

    #[test]
    fn a_trailing_run_of_punctuation_is_dropped_but_an_inner_one_is_kept() {
        assert_eq!(spans("https://x.example/a.b?c=d!"), vec![(0, 25)]);
        assert_eq!(at("(https://x.example/a)", 2).as_deref(), Some("https://x.example/a"));
        assert_eq!(at("(https://x.example/a)", 21).as_deref(), None, "the closing parenthesis is not part of it");
    }

    #[test]
    fn byte_offsets_are_what_lua_can_slice() {
        let box_bar = '\u{2502}';
        let text = format!("{box_bar} https://x.example/a {box_bar}");
        let (start, end) = first_bytes(&text).expect("a span");
        assert_eq!(&text[start..end], "https://x.example/a");
    }

    #[test]
    fn a_wide_character_owns_both_of_its_cells() {
        let line = "\u{4f60}\u{597d} https://x.example";
        // columns 1 and 2 are the first character, 3 and 4 the second, 5 the space.
        assert_eq!(char_at_cell(line, 1), Some(0));
        assert_eq!(char_at_cell(line, 2), Some(0));
        assert_eq!(char_at_cell(line, 3), Some(1));
        assert_eq!(char_at_cell(line, 4), Some(1));
        assert_eq!(char_at_cell(line, 6), Some(3), "the h of https");
        assert_eq!(at(line, 8).as_deref(), Some("https://x.example"));
    }
}
