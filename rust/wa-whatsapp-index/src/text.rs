//! What a message is searchable by: the fold, the tokens, and the one place that says which fields are
//! searched.
//!
//! Two writers need this. The component indexes a message when it arrives and searches when it is
//! asked; the node puts a month back after a restore and must recompute *exactly* the token keys the
//! component would have written, or the restored month is readable by `whatsapp_read` and invisible to
//! `whatsapp_search`. A second copy of the fold in the node is the drift this module exists to prevent:
//! one accent table updated in one crate and not the other is a search that silently stops matching.
//!
//! [`Searchable`] is also the one statement of *which* fields are searched, in the order they are
//! concatenated: the body, the transcription, the OCR text, a media filename and mime, a place, a
//! poll's question and options, and the names of shared contacts.

/// Most token keys one record writes. A long document's caption is not a thesaurus.
pub const MAX_TOKENS: usize = 48;

/// Fold a string into what a token index compares: lowercase, accents stripped, everything that is not
/// a letter or a digit becomes a separator.
///
/// The Go connector searched with SQLite's `LIKE` on the raw body, so `ação` never matched `acao` and
/// a document named `Relatório.pdf` was unfindable as `relatorio`. Folding is what makes the index
/// worth having; it is done on the way in *and* on the way out, so a query typed either way matches.
pub fn fold(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        let lower = ch.to_lowercase().next().unwrap_or(ch);
        let code = lower as u32;
        let folded = if (0xC0..=0xFF).contains(&code) {
            mapped(LATIN1, code - 0xC0, lower)
        } else if (0x100..=0x17F).contains(&code) {
            mapped(LATIN_EXT_A, code - 0x100, lower)
        } else {
            lower
        };
        // Letters and digits are the tokens; so is an emoji, because a sticker is found by the emoji
        // its sender tagged it with and "an emoji" has no letters to fold. Everything else separates.
        if folded.is_alphanumeric() || is_emoji(folded) {
            out.push(folded);
        } else {
            out.push(' ');
        }
    }
    out
}

/// One entry of a folding table, or the character itself when the table has no opinion (`?`).
fn mapped(table: &str, index: u32, fallback: char) -> char {
    match table.chars().nth(index as usize) {
        Some('?') | None => fallback,
        Some(folded) => folded,
    }
}

/// A symbol that is not punctuation: what an emoji is, and what a token may be.
fn is_emoji(ch: char) -> bool {
    !ch.is_ascii() && !ch.is_whitespace() && !ch.is_alphanumeric() && !is_punctuation(ch)
}

/// Punctuation, which never belongs to a token (an emoji is a symbol, not punctuation).
fn is_punctuation(ch: char) -> bool {
    ch.is_ascii_punctuation()
        || ('\u{a1}'..='\u{bf}').contains(&ch)
        || ('\u{2010}'..='\u{2027}').contains(&ch)
        || ('\u{2030}'..='\u{205e}').contains(&ch)
        || ('\u{3000}'..='\u{303f}').contains(&ch)
}

/// The tokens of a text: folded, split, bounded, deduplicated in place by the caller.
pub fn tokenize(text: &str) -> Vec<String> {
    let mut tokens: Vec<String> = Vec::new();
    for token in fold(text).split_whitespace() {
        let chars = token.chars().count();
        if chars == 0 || chars > 40 {
            continue;
        }
        // A one-character token is dropped when it is a letter or a digit (nobody searches "a") and
        // kept when it is an emoji: a sticker is indexed by the emoji it was tagged with, and by
        // nothing else.
        if chars == 1 && token.chars().next().is_some_and(|ch| ch.is_alphanumeric()) {
            continue;
        }
        let token = token.to_string();
        if !tokens.iter().any(|seen| seen == &token) {
            tokens.push(token);
        }
    }
    tokens
}

/// The tokens one record's searchable text becomes: folded, deduplicated, bounded by [`MAX_TOKENS`].
pub fn tokens(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for token in tokenize(text) {
        if out.len() >= MAX_TOKENS {
            break;
        }
        if !out.iter().any(|seen| seen == &token) {
            out.push(token);
        }
    }
    out
}

/// The fields a message is searched by, in the order they are concatenated.
///
/// Borrowed on purpose: the component builds one from a `Record` it already owns, and the node builds
/// one from the record JSON it archived, so neither has to clone a message to ask what it is
/// searchable by.
#[derive(Clone, Debug, Default)]
pub struct Searchable<'a> {
    /// The body, the transcription and the OCR text - in that order, the non-empty ones only.
    pub body: &'a [&'a str],
    /// A media message's `(filename, mime)`, when it has media.
    pub media: Option<(&'a str, &'a str)>,
    /// A location's `(name, address)`.
    pub place: Option<(&'a str, &'a str)>,
    /// A poll's `(question, options)`.
    pub poll: Option<(&'a str, &'a [&'a str])>,
    /// The names of the contacts one message shares.
    pub contacts: &'a [&'a str],
}

impl<'a> Searchable<'a> {
    /// The one haystack: what a search matches against, byte for byte the same in both crates.
    pub fn text(&self) -> String {
        let mut out = String::new();
        for part in self.body {
            if !part.is_empty() {
                out.push_str(part);
                out.push(' ');
            }
        }
        if let Some((filename, mime)) = self.media {
            out.push_str(filename);
            out.push(' ');
            out.push_str(mime);
        }
        if let Some((name, address)) = self.place {
            out.push_str(name);
            out.push(' ');
            out.push_str(address);
        }
        if let Some((question, options)) = self.poll {
            out.push_str(question);
            for option in options {
                out.push(' ');
                out.push_str(option);
            }
        }
        for contact in self.contacts {
            out.push(' ');
            out.push_str(contact);
        }
        out
    }

    /// The token keys this record writes ([`MAX_TOKENS`] at most, deduplicated, folded).
    pub fn tokens(&self) -> Vec<String> {
        tokens(&self.text())
    }
}

/// Latin-1 supplement (U+00C0..U+00FF), one ASCII letter per character (`?` = no opinion).
pub const LATIN1: &str = "AAAAAAACEEEEIIIIDNOOOOO?OUUUUYTsaaaaaaaceeeeiiiidnooooo?ouuuuyty";

/// Latin Extended-A (U+0100..U+017F): the Polish, Czech, Baltic and Turkish letters a Portuguese or
/// English speaker still types without the accent.
pub const LATIN_EXT_A: &str = concat!(
    "AaAaAaCcCcCcCcDd",
    "DdEeEeEeEeGgGgGg",
    "GgGgGgHhHhIiIiIi",
    "IiIiJjKkkLlLlLlL",
    "lLlNnNnNnnNnOoOo",
    "OoOoRrRrRrSsSsSs",
    "SsTtTtTtUuUuUuUu",
    "UuUuWwYyYZzZzZzs",
);

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keys::{RecordFacts, PREFIX};

    #[test]
    fn folding_is_what_makes_an_accented_search_find_an_unaccented_word() {
        assert_eq!(fold("Ação"), "acao");
        assert_eq!(fold("Relatório.pdf"), "relatorio pdf");
        assert_eq!(fold("Zażółć"), "zazolc");
        assert_eq!(tokenize("Acao acao ACAO"), vec!["acao".to_string()]);
        assert_eq!(tokenize("uma a de o"), vec!["uma".to_string(), "de".to_string()], "a one-letter word is not a token");
        assert_eq!(tokenize("\u{1f602}"), vec!["\u{1f602}".to_string()], "an emoji is a token");
    }

    #[test]
    fn the_token_list_is_deduplicated_and_bounded() {
        assert!(tokenize(&"palavra ".repeat(200)).len() <= 200);
        // The bound is the record's, not the text's: a thesaurus-sized caption writes MAX_TOKENS keys.
        let words: Vec<String> = (0..MAX_TOKENS * 2).map(|n| format!("w{n}")).collect();
        let answer = tokens(&words.join(" "));
        assert_eq!(answer.len(), MAX_TOKENS);
        assert_eq!(answer[0], "w0");
        assert_eq!(answer[MAX_TOKENS - 1], format!("w{}", MAX_TOKENS - 1));
        // Deduplicated: the same word twice is one key.
        assert_eq!(tokens("acao acao acao"), vec!["acao".to_string()]);
    }

    #[test]
    fn the_searchable_text_is_the_same_haystack_the_index_was_built_on() {
        // The order is the contract: body, transcription, OCR, media, place, poll, contacts. A restore
        // that concatenated these differently would write different tokens than the live index did.
        let options = ["Sushi", "Pizza"];
        let contacts = ["Laura"];
        let searchable = Searchable {
            body: &["uma nota", "", "texto do ocr"],
            media: Some(("Relatório.pdf", "application/pdf")),
            place: Some(("Casa", "Rua Um 10")),
            poll: Some(("Onde jantar?", &options)),
            contacts: &contacts,
        };
        let text = searchable.text();
        // Verbatim, because this is the haystack the live index was built on: the body parts each keep
        // their trailing space, and the media, place, poll and contact parts are appended without one
        // (the separator is the space `tokenize` folds them across). A restore that "tidied" this would
        // write different token keys than the ones the month was cut with.
        assert_eq!(text, "uma nota texto do ocr Relatório.pdf application/pdfCasa Rua Um 10Onde jantar? Sushi Pizza Laura");
        let tokens = searchable.tokens();
        for expected in ["uma", "nota", "texto", "do", "ocr", "relatorio", "pdf", "application", "pdfcasa", "rua", "10onde", "jantar", "sushi", "pizza", "laura"] {
            assert!(tokens.iter().any(|token| token == expected), "{expected} is a token of {tokens:?}");
        }
        assert!(!tokens.iter().any(|token| token == "a"), "a one-letter word is not a token");
        assert!(!tokens.iter().any(|token| token == "casa"), "the parts are concatenated, not separated - folded the way the index folds them");
    }

    #[test]
    fn a_restore_writes_the_same_token_keys_the_component_would_have() {
        // The two halves meet here: the facts the node derives from an archived record produce exactly
        // the keys the component wrote live - no more (a missed one is a search that cannot find the
        // month) and no fewer (an extra one is a key pointing at a record that is not there).
        let searchable = Searchable { body: &["Ação relatada"], ..Searchable::default() };
        let facts = RecordFacts {
            chat: "5511999999999@s.whatsapp.net".into(),
            id: "3EB0".into(),
            sender: "5511888888888@s.whatsapp.net".into(),
            ts: 1_700_000_000_000,
            kind: "text".into(),
            source: String::new(),
            tokens: searchable.tokens(),
        };
        let keys = facts.keys();
        assert_eq!(keys.len(), 7);
        assert!(keys[5].starts_with("ix/w/acao/"), "{:?} is the folded token key", keys[5]);
        for key in &keys {
            assert!(key.starts_with(PREFIX), "{key} is not an index key");
        }
    }
}
