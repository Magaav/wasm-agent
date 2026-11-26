//! The transcript capability, on the far side of the wire: ONE `Transcript` and the table of calls the
//! node makes on it (`wa-term-proto`).
//!
//! This is the half that makes a display-only change shippable without a host build: every row the
//! reader sees - the pinned request, the notice row, the scrollbar, the wrapping - is decided here,
//! and the node only says what happened (a block started, a line was written, the wheel moved).
//!
//! The clock is this process's own: `notice`, `expire_notice` and a frame's notice row read
//! `Instant::now()` HERE, so no time crosses the wire and the two-second rule keeps one owner.

use serde_json::{json, Value};
use wa_term_proto as proto;

use crate::scroll::bar::Bar;
use crate::scroll::settings::Scrollbar;
use crate::transcript::Transcript;

/// One terminal program's transcript, and the calls it answers.
pub struct Session {
    pub transcript: Transcript,
}

impl Default for Session {
    fn default() -> Self { Self::new() }
}

impl Session {
    pub fn new() -> Self { Session { transcript: Transcript::default() } }

    /// The flag the node gates its frames on.
    pub fn dirty(&self) -> bool { self.transcript.dirty }

    /// One call, answered: its value, or the refusal this program names.
    ///
    /// An unknown method is `term_unknown_method` (a node newer than this program), never a silent
    /// nothing: a node whose call vanished would draw a frame that is missing its rows.
    pub fn handle(&mut self, call: &proto::Call) -> Result<Value, proto::Failure> {
        let t = &mut self.transcript;
        let a = &call.args;
        let unknown = || proto::Failure::new(proto::code::UNKNOWN_METHOD, format!("this program has no method '{}' (protocol {})", call.method, proto::PROTOCOL));
        Ok(match call.method.as_str() {
            // ---- the chat, as the node's Lua view feeds it ----
            "write" => { t.write(text(a, 0)?); Value::Null }
            "write_marked" => { t.write_marked(text(a, 0)?, flag(a, 1)?); Value::Null }
            "block" => { t.block(flag(a, 0)?); Value::Null }
            "code_block" => { t.code_block(); Value::Null }
            "fold_code" => json!(t.fold_code(text(a, 0)?)),
            "head" => json!(t.head(text(a, 0)?)),
            "live" => { t.live(optional_text(a, 0)?); Value::Null }
            "rewrite" => json!(t.rewrite(number(a, 0)?, text(a, 1)?)),
            "pin_toggle" => match t.pin_toggle() { Some(pinned) => json!(pinned), None => Value::Null },
            "copyable" => { t.copyable(&marks(a, 0)?); Value::Null }
            "expandable" => { t.expandable(&marks(a, 0)?); Value::Null }
            "cardable" => { t.cardable(&ranges(a, 0)?); Value::Null }
            "copy_first" => json!(t.copy_first(text(a, 0)?)),
            "copy_at" => match t.copy_at(count(a, 0)?, count(a, 1)?) { Some(text) => json!(text), None => Value::Null },
            "copy_hover" => json!(t.copy_hover(count(a, 0)?, count(a, 1)?)),
            "expand_at" => json!(t.expand_at(count(a, 0)?)),
            "expand_hover" => json!(t.expand_hover(count(a, 0)?)),
            "topics" => json!(t.topics()),
            // ---- navigation ----
            "focus_prev" => json!(t.focus_prev()),
            "focus_next" => json!(t.focus_next()),
            "set_expanded" => { t.set_expanded(flag(a, 0)?); Value::Null }
            "unfocus" => { t.unfocus(); Value::Null }
            "page" => { t.page(number(a, 0)?); Value::Null }
            "hold" => { t.hold(); Value::Null }
            "sync" => { t.sync(); Value::Null }
            "to_bottom" => { t.to_bottom(); Value::Null }
            "following" => json!(t.following()),
            // ---- the notice row (this process's clock) ----
            "notice" => json!(t.notice(text(a, 0)?, std::time::Instant::now(), flag(a, 1)?)),
            "clear_notice" => json!(t.clear_notice()),
            "expire_notice" => json!(t.expire_notice(std::time::Instant::now())),
            "on_pin" => json!(t.on_pin(count(a, 0)?)),
            "on_notice" => json!(t.on_notice(count(a, 0)?)),
            "on_pill" => json!(t.on_pill(count(a, 0)?, count(a, 1)?, count(a, 2)?)),
            "jump_to_pinned" => json!(t.jump_to_pinned(count(a, 0)?)),
            // ---- the frame ----
            "view" => json!(t.view(count(a, 0)?, count(a, 1)?)),
            "render" => json!({ "frame": proto::bytes(t.render(count(a, 0)?, count(a, 1)?).as_bytes()) }),
            "bar_frame" => json!({ "frame": proto::bytes(t.bar_frame(count(a, 0)?).as_bytes()) }),
            "text_width" => json!(t.text_width(count(a, 0)?)),
            "last_is_code" => json!(t.blocks.last().is_some_and(|block| block.code)),
            // ---- the scrollbar ----
            "bar" => match t.bar() {
                Some(bar) => bar_value(bar),
                None => Value::Null,
            },
            "on_bar" => json!(t.on_bar(count(a, 0)?, count(a, 1)?, count(a, 2)?)),
            "bar_press" => json!(t.bar_press(count(a, 0)?, count(a, 1)?, count(a, 2)?)),
            "bar_drag" => json!(t.bar_drag(count(a, 0)?)),
            "bar_release" => json!(t.bar_release()),
            "bar_hover" => json!(t.bar_hover(count(a, 0)?, count(a, 1)?, count(a, 2)?)),
            "bar_active" => json!(t.bar_active()),
            // The node's setting (`WA_TUI_SCROLLBAR`), handed over rather than read from the
            // environment a second time: one reader, one meaning.
            "scrollbar" => {
                let name = text(a, 0)?.to_string();
                match Scrollbar::parse(&name) {
                    Some(bar) => { t.scrollbar = bar; Value::Null }
                    None => return Err(proto::Failure::new(proto::code::BAD_MESSAGE, format!("no scrollbar setting called '{name}'"))),
                }
            }
            // The node's own flag (`transcript.dirty`), set from its side: it decides a frame and
            // nothing in this crate reads it.
            "dirty" => { t.dirty = flag(a, 0)?; Value::Null }
            _ => return Err(unknown()),
        })
    }
}

/// A bar as JSON: its four numbers, so the node's hit tests keep the same shape they had in process.
fn bar_value(bar: Bar) -> Value {
    json!({ "track": bar.track, "total": bar.total, "first": bar.first, "active": bar.active })
}

fn text<'a>(args: &'a [Value], at: usize) -> Result<&'a str, proto::Failure> {
    args.get(at).and_then(Value::as_str)
        .ok_or_else(|| proto::Failure::new(proto::code::BAD_MESSAGE, format!("argument {at} must be a string")))
}

fn optional_text(args: &[Value], at: usize) -> Result<Option<&str>, proto::Failure> {
    match args.get(at) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text)),
        Some(other) => Err(proto::Failure::new(proto::code::BAD_MESSAGE, format!("argument {at} must be a string or null, not {other}"))),
    }
}

fn number(args: &[Value], at: usize) -> Result<isize, proto::Failure> {
    args.get(at).and_then(Value::as_i64).map(|value| value as isize)
        .ok_or_else(|| proto::Failure::new(proto::code::BAD_MESSAGE, format!("argument {at} must be a number")))
}

fn count(args: &[Value], at: usize) -> Result<usize, proto::Failure> {
    let value = number(args, at)?;
    usize::try_from(value).map_err(|_| proto::Failure::new(proto::code::BAD_MESSAGE, format!("argument {at} must not be negative: {value}")))
}

fn flag(args: &[Value], at: usize) -> Result<bool, proto::Failure> {
    args.get(at).and_then(Value::as_bool)
        .ok_or_else(|| proto::Failure::new(proto::code::BAD_MESSAGE, format!("argument {at} must be true or false")))
}

/// The copy/expand markers: `[[row, "the marker"], ...]`, as `lua/core/cli_view.lua` builds them.
fn marks(args: &[Value], at: usize) -> Result<Vec<(usize, String)>, proto::Failure> {
    let list = args.get(at).and_then(Value::as_array)
        .ok_or_else(|| proto::Failure::new(proto::code::BAD_MESSAGE, format!("argument {at} must be a list of [row, marker]")))?;
    list.iter().map(|item| {
        let pair = item.as_array().filter(|pair| pair.len() == 2)
            .ok_or_else(|| proto::Failure::new(proto::code::BAD_MESSAGE, format!("a marker that is not [row, text]: {item}")))?;
        let row = pair[0].as_u64().ok_or_else(|| proto::Failure::new(proto::code::BAD_MESSAGE, format!("a marker's row is not a number: {item}")))?;
        let text = pair[1].as_str().ok_or_else(|| proto::Failure::new(proto::code::BAD_MESSAGE, format!("a marker's text is not a string: {item}")))?;
        Ok((row as usize, text.to_string()))
    }).collect()
}

fn ranges(args: &[Value], at: usize) -> Result<Vec<(usize, usize)>, proto::Failure> {
    let list = args.get(at).and_then(Value::as_array)
        .ok_or_else(|| proto::Failure::new(proto::code::BAD_MESSAGE, format!("argument {at} must be a list of [first, last]")))?;
    list.iter().map(|item| {
        let pair = item.as_array().filter(|pair| pair.len() == 2)
            .ok_or_else(|| proto::Failure::new(proto::code::BAD_MESSAGE, format!("a range that is not [first, last]: {item}")))?;
        let first = pair[0].as_u64().ok_or_else(|| proto::Failure::new(proto::code::BAD_MESSAGE, format!("a range's first row is not a number: {item}")))?;
        let last = pair[1].as_u64().ok_or_else(|| proto::Failure::new(proto::code::BAD_MESSAGE, format!("a range's last row is not a number: {item}")))?;
        Ok((first as usize, last as usize))
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use wa_term_proto::parse_call;

    fn call(method: &str, args: Value) -> proto::Call {
        parse_call(&json!({ "v": proto::PROTOCOL, "op": "call", "method": method, "args": args })).expect("a call")
    }

    #[test]
    fn a_method_this_program_does_not_have_is_named_not_ignored() {
        let mut session = Session::new();
        let failure = session.handle(&call("widgets", json!([]))).expect_err("a refusal");
        assert_eq!(failure.code, "term_unknown_method");
        assert!(failure.message.contains("widgets"), "{}", failure.message);
    }

    #[test]
    fn a_rendered_frame_crosses_the_wire_byte_for_byte() {
        // The same transcript, drawn once here and once through the answer the node decodes: this is
        // the property the pty row and the two-process row then prove at the far end.
        let mut session = Session::new();
        session.transcript.block(false);
        session.transcript.write("a line of the chat");
        session.transcript.notice("Copied 3 characters", std::time::Instant::now(), false);
        let expected = session.transcript.render(40, 10);
        let answer = session.handle(&call("render", json!([40, 10]))).expect("a frame");
        let bytes = proto::unbytes(answer["frame"].as_str().expect("a frame")).expect("base64");
        assert_eq!(String::from_utf8(bytes).expect("utf-8"), expected);
        assert!(session.dirty(), "and the dirty flag rides with the answer");
    }

    #[test]
    fn a_scrollbar_setting_the_node_cannot_name_is_refused() {
        let mut session = Session::new();
        assert!(session.handle(&call("scrollbar", json!(["always"]))).is_ok());
        assert_eq!(session.transcript.scrollbar, Scrollbar::Always);
        let failure = session.handle(&call("scrollbar", json!(["banana"]))).expect_err("a refusal");
        assert_eq!(failure.code, "term_bad_message");
        assert!(failure.message.contains("banana"), "{}", failure.message);
    }
}
