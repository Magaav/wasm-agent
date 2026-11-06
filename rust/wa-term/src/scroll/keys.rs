//! Turning the terminal's bytes into the chat's keys.
//!
//! The input editor already decodes every editing sequence it needs (`terminal_editor::feed`), so
//! this decoder is deliberately narrow: it names only the keys a scroll binding can mention
//! (`settings::KEYS`) and hands everything else through as the bytes it read, which the caller feeds
//! to the editor unchanged. That division is what keeps the fullscreen chat from stealing a chord
//! from the draft: a key this module does not name is a key the editor still gets.
//!
//! Both the classic (`ESC [ A`) and the modified (`ESC [ 1 ; 5 H`) forms are decoded, plus the
//! rxvt forms (`ESC O a`), because "Ctrl+Home" is reported four different ways by four terminals.
use crate::scroll::settings::KEYS;

/// One key from the terminal: the name a binding can use (if it has one), and the exact bytes, which
/// are forwarded to the input editor when no binding claimed the key.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Key { pub name: Option<&'static str>, pub raw: Vec<u8> }

impl Key {
    pub fn named(name: &'static str, raw: Vec<u8>) -> Key { Key { name: Some(name), raw } }
    fn other(raw: Vec<u8>) -> Key { Key { name: None, raw } }
    /// The sequence is still arriving: nothing to do and nothing to forward yet.
    pub fn pending(&self) -> bool { self.name.is_none() && self.raw.is_empty() }
}

const PENDING: Key = Key { name: None, raw: Vec::new() };

#[derive(Default)]
pub struct Decoder { sequence: Vec<u8> }

impl Decoder {
    pub fn feed(&mut self, byte: u8) -> Key {
        if self.sequence.is_empty() {
            // A single byte: the control keys a binding can name, then everything else.
            match byte {
                0x1b => { self.sequence.push(byte); return PENDING; }
                0x0f => return Key::named("ctrl+o", vec![byte]),
                0x14 => return Key::named("ctrl+t", vec![byte]),
                0x15 => return Key::named("ctrl+u", vec![byte]),
                0x04 => return Key::named("ctrl+d", vec![byte]),
                0x19 => return Key::named("ctrl+y", vec![byte]),
                _ => return Key::other(vec![byte]),
            }
        }
        self.sequence.push(byte);
        let sequence = self.sequence.clone();
        // Two Escapes are the Esc key twice, not the start of a sequence (the editor reads it as one
        // Esc, which is what a reader pressing Esc twice meant).
        if sequence == b"\x1b\x1b" { self.sequence.clear(); return Key::other(sequence); }
        // `ESC` + one byte that cannot begin a sequence is Alt+<key> - never a sequence.
        if sequence.len() == 2 && !matches!(byte, b'[' | b'O' | b'\r' | b'\n' | 0x1b) {
            self.sequence.clear();
            return match byte {
                b'v' => Key::named("alt+v", sequence),
                _ => Key::other(sequence),
            };
        }
        // An escape sequence's last byte ends it; a CSI sequence's parameters are ASCII before it.
        let complete = sequence.len() >= 3 && (0x40..=0x7e).contains(&sequence[sequence.len() - 1]);
        if sequence.len() > 24 {
            self.sequence.clear();
            return Key::other(sequence);
        }
        if !complete { return PENDING; }
        self.sequence.clear();
        let body = String::from_utf8_lossy(&sequence[2..sequence.len() - 1]).to_string();
        let kind = sequence[1];
        let last = sequence[sequence.len() - 1] as char;
        let name = match (kind, last, body.as_str()) {
            (b'[', 'A', "") | (b'O', 'A', "") => Some("up"),
            (b'[', 'B', "") | (b'O', 'B', "") => Some("down"),
            (b'[', 'a', "") | (b'O', 'a', "") => Some("shift+up"),
            (b'[', 'b', "") | (b'O', 'b', "") => Some("shift+down"),
            (b'[', 'H', "") | (b'[', 'H', "1") | (b'[', '~', "1") | (b'[', '~', "7") => Some("home"),
            (b'[', 'F', "") | (b'[', 'F', "1") | (b'[', '~', "4") | (b'[', '~', "8") => Some("end"),
            (b'[', 'H', "1;5") | (b'[', '~', "1;5") | (b'[', '~', "7;5") => Some("ctrl+home"),
            (b'[', 'F', "1;5") | (b'[', '~', "4;5") | (b'[', '~', "8;5") => Some("ctrl+end"),
            (b'[', 'A', "1;2") => Some("shift+up"),
            (b'[', 'B', "1;2") => Some("shift+down"),
            (b'[', '~', "5") => Some("pageup"),
            (b'[', '~', "6") => Some("pagedown"),
            (b'[', '~', "15") => Some("f5"),
            (b'[', '~', "17") => Some("f6"),
            _ => None,
        };
        match name.filter(|name| KEYS.contains(name)) {
            Some(name) => Key::named(name, sequence),
            None => Key::other(sequence), // an unknown sequence: the editor's decoder knows it
        }
    }

    /// A lone `ESC` - the terminal sent nothing after it - is the Esc key, not a sequence. The caller
    /// asks after a short wait, the way the input editor does; without this an Esc would be held
    /// forever and a reader could not close a menu.
    pub fn lone_escape(&mut self) -> Option<Key> {
        if self.sequence.as_slice() == b"\x1b" { self.sequence.clear(); return Some(Key::other(b"\x1b".to_vec())); }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys(decoder: &mut Decoder, bytes: &[u8]) -> Vec<Key> {
        let mut out = Vec::new();
        for &byte in bytes {
            let key = decoder.feed(byte);
            if !key.pending() { out.push(key); }
        }
        out
    }

    #[test]
    fn the_page_and_end_keys_are_named_in_every_form_a_terminal_sends() {
        let mut decoder = Decoder::default();
        assert_eq!(keys(&mut decoder, b"\x1b[5~")[0].name, Some("pageup"));
        assert_eq!(keys(&mut decoder, b"\x1b[6~")[0].name, Some("pagedown"));
        for sequence in [b"\x1b[1;5H".as_slice(), b"\x1b[1;5~", b"\x1b[7;5~"] {
            assert_eq!(keys(&mut decoder, sequence)[0].name, Some("ctrl+home"), "{:?}", String::from_utf8_lossy(sequence));
        }
        for sequence in [b"\x1b[1;5F".as_slice(), b"\x1b[4;5~", b"\x1b[8;5~"] {
            assert_eq!(keys(&mut decoder, sequence)[0].name, Some("ctrl+end"), "{:?}", String::from_utf8_lossy(sequence));
        }
        assert_eq!(keys(&mut decoder, b"\x1b[1;2A")[0].name, Some("shift+up"));
        assert_eq!(keys(&mut decoder, b"\x1bOa")[0].name, Some("shift+up"), "rxvt");
        assert_eq!(keys(&mut decoder, b"\x1b[15~")[0].name, Some("f5"));
        assert_eq!(keys(&mut decoder, b"\x0f")[0].name, Some("ctrl+o"));
        assert_eq!(keys(&mut decoder, b"\x14")[0].name, Some("ctrl+t"));
        assert_eq!(keys(&mut decoder, b"\x1b[1;2B")[0].name, Some("shift+down"));
        assert_eq!(keys(&mut decoder, b"\x1b\x1b")[0].raw, b"\x1b\x1b".to_vec(), "two Escapes are forwarded, not swallowed");
    }

    #[test]
    fn a_key_the_chat_does_not_name_is_forwarded_byte_for_byte() {
        let mut decoder = Decoder::default();
        // Letters, Ctrl+A (the editor's start of line), an arrow left, and a CSI the chat never uses.
        let typed = b"ab\x01\x1b[D\x1b[38;5;9m";
        let out = keys(&mut decoder, typed);
        let forwarded: Vec<u8> = out.iter().flat_map(|key| key.raw.clone()).collect();
        assert_eq!(forwarded, typed, "nothing is eaten between here and the draft: {out:?}");
        assert!(out.iter().all(|key| key.name.is_none()));
        // Alt+V is named (bindable), everything else after Alt is not.
        assert_eq!(keys(&mut decoder, b"\x1bv")[0].name, Some("alt+v"));
        assert_eq!(keys(&mut decoder, b"\x1bx")[0].raw, b"\x1bx".to_vec());
    }

    #[test]
    fn a_lone_escape_is_the_escape_key_and_a_split_sequence_waits() {
        let mut decoder = Decoder::default();
        assert!(decoder.feed(0x1b).pending());
        assert_eq!(decoder.lone_escape(), Some(Key::other(b"\x1b".to_vec())));
        assert_eq!(decoder.lone_escape(), None, "asked once");

        assert!(decoder.feed(0x1b).pending());
        assert!(decoder.feed(b'[').pending());
        assert!(decoder.feed(b'1').pending(), "a sequence split across two reads is not an Esc");
        assert_eq!(decoder.lone_escape(), None);
        assert!(decoder.feed(b';').pending());
        assert_eq!(decoder.feed(b'5').name, None);
        assert_eq!(decoder.feed(b'H').name, Some("ctrl+home"));
    }
}
