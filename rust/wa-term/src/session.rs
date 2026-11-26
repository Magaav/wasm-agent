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
use crate::terminal_editor::{Action, Command, Editor};
use crate::transcript::Transcript;

/// One terminal program's transcript, and the calls it answers.
pub struct Session {
    pub transcript: Transcript,
    /// The input box, owned HERE (part 2 of `wa-term-own-program`): the node sets its state over the
    /// wire (`editor_setup`), sends the key bytes (`editor_key`) and draws what `editor_render`
    /// and `editor_state` answer. The node holds no Editor and links none.
    pub editor: Editor,
}

impl Default for Session {
    fn default() -> Self { Self::new() }
}

impl Session {
    pub fn new() -> Self { Session { transcript: Transcript::default(), editor: Editor::default() } }

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
            // ---- the editor: the node's input box. The node holds no Editor; it sets its state,
            // sends the key bytes and draws the rows this process answers. ----
            "editor_open" => { self.editor = Editor::default(); Value::Null }
            "editor_setup" => { editor_setup(&mut self.editor, a)?; Value::Null }
            "editor_key" => {
                let byte = u8::try_from(count(a, 0)?).map_err(|_| proto::Failure::new(proto::code::BAD_MESSAGE, "a key byte must be 0..=255"))?;
                json!(action_value(self.editor.feed(byte)))
            }
            "editor_state" => json!(editor_state(&self.editor)),
            "editor_render" => json!({ "frame": proto::bytes(self.editor.render().as_bytes()) }),
            "editor_paste" => json!(action_value(self.editor.paste(text(a, 0)?))),
            "editor_insert" => { self.editor.insert_text(text(a, 0)?); Value::Null }
            "editor_replace" => { self.editor.replace_range(count(a, 0)?, count(a, 1)?, text(a, 2)?); Value::Null }
            "editor_select" => { self.editor.select(count(a, 0)?, count(a, 1)?); Value::Null }
            "editor_slice" => json!(self.editor.slice(count(a, 0)?, count(a, 1)?)),
            "editor_selection" => match self.editor.selected_text() { Some(text) => json!(text), None => Value::Null },
            "editor_click" => { self.editor.click(count(a, 0)?); Value::Null }
            "editor_wheel" => json!(self.editor.wheel(flag(a, 0)?, count(a, 1)?)),
            "editor_escape" => json!(self.editor.escape()),
            _ => return Err(unknown()),
        })
    }
}


/// An Action as the node reads it: a tag and, where the tag carries one, its text or index. The
/// node's console loop matches on `kind` exactly where it used to match the enum.
fn action_value(action: Action) -> Value {
    match action {
        Action::None => json!({ "kind": "none" }),
        Action::Submit(text) => json!({ "kind": "submit", "text": text }),
        Action::SubmitNow(text) => json!({ "kind": "submit_now", "text": text }),
        Action::Eof => json!({ "kind": "eof" }),
        Action::Interrupt => json!({ "kind": "interrupt" }),
        Action::Nav => json!({ "kind": "nav" }),
        Action::PageUp => json!({ "kind": "page_up" }),
        Action::PageDown => json!({ "kind": "page_down" }),
        Action::Bottom => json!({ "kind": "bottom" }),
        Action::Copy(text) => json!({ "kind": "copy", "text": text }),
        Action::Paste => json!({ "kind": "paste" }),
        Action::Pasted(from) => json!({ "kind": "pasted", "from": from }),
    }
}

/// The input box's whole state, as the node draws and lays out from it. Every number the node used to
/// read off `Editor` in process is here, computed by the editor that owns it.
fn editor_state(editor: &Editor) -> Value {
    json!({
        "draft": editor.draft(),
        "selection": match editor.selection() { Some((a, b)) => json!([a, b]), None => Value::Null },
        "empty": editor.draft_empty(),
        "bash": editor.bash,
        "pasting": editor.pasting(),
        "row": editor.row,
        "width": editor.width,
        "height": editor.height,
        "status": editor.status,
        "out_bottom": editor.out_bottom(),
        "status_row": editor.status_row(),
        "footer_row": editor.footer_row(),
        "session_row": editor.session_row(),
        "wakes_row": editor.wakes_row(),
        "bottom": editor.bottom(),
        "box_rows": match editor.box_rows() { Some((top, bottom)) => json!([top, bottom]), None => Value::Null },
        "menu_rows": editor.menu_rows(),
        "footer": editor.footer,
        "footer_right": editor.footer_right,
        "wakes_content": editor.wakes_content(),
        "session_content": editor.session_content(),
        "cursor_frame": editor.cursor_frame(),
    })
}

/// Set the editor's state from the node, one object per change; a key that is absent keeps what the
/// editor has. The node sends the whole object after a change it knows about, so there is one shape
/// and no "unset" ambiguity.
fn editor_setup(editor: &mut Editor, args: &[Value]) -> Result<(), proto::Failure> {
    let spec = args.first().and_then(Value::as_object)
        .ok_or_else(|| proto::Failure::new(proto::code::BAD_MESSAGE, "argument 0 must be the editor's setup object"))?;
    let size = |key: &str| spec.get(key).and_then(Value::as_i64).and_then(|n| usize::try_from(n).ok());
    let line = |key: &str| spec.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
    if let Some(n) = size("row") { editor.row = n; }
    if let Some(n) = size("width") { editor.width = n; }
    if let Some(n) = size("height") { editor.height = n; }
    if let Some(flag) = spec.get("status").and_then(Value::as_bool) { editor.status = flag; }
    if let Some(flag) = spec.get("bash").and_then(Value::as_bool) { editor.bash = flag; }
    if spec.contains_key("queued") { editor.queued = strings(spec.get("queued")); }
    if spec.contains_key("history") { editor.set_history(strings(spec.get("history"))); }
    if let Some(list) = spec.get("commands") {
        editor.commands = list.as_array().map(|items| items.iter().filter_map(|item| {
            let name = item.get("name").and_then(Value::as_str)?.to_string();
            Some(Command {
                name,
                args: item.get("args").and_then(Value::as_bool).unwrap_or(false),
                hint: item.get("hint").and_then(Value::as_str).unwrap_or_default().to_string(),
            })
        }).collect()).unwrap_or_default();
    }
    for key in ["wakes", "build", "session_notice", "footer", "footer_right"] {
        if !spec.contains_key(key) { continue; }
        let value = line(key);
        match key {
            "wakes" => editor.wakes = value,
            "build" => editor.build = value,
            "session_notice" => editor.session_notice = value,
            "footer" => editor.footer = value,
            _ => editor.footer_right = value,
        }
    }
    Ok(())
}

/// A JSON array of strings, missing or null being none.
fn strings(value: Option<&Value>) -> Vec<String> {
    value.and_then(Value::as_array).map(|items| items.iter().filter_map(Value::as_str).map(str::to_string).collect()).unwrap_or_default()
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
    fn the_input_box_crosses_the_wire_with_its_geometry_and_its_actions() {
        let mut session = Session::new();
        let setup = json!([{ "row": 23, "width": 80, "height": 24, "status": false,
            "wakes": "wakes", "build": "", "session_notice": "", "footer": "model", "footer_right": "opus",
            "history": ["first line", "!ls"], "commands": [{ "name": "/login", "args": false, "hint": "sign in" }] }]);
        session.handle(&call("editor_setup", setup)).expect("a setup");

        // The same editor built here, field by field, is the ruler: every number the wire answers has
        // to be the number the node used to read off the struct.
        let mut local = Editor::default();
        local.row = 23;
        local.width = 80;
        local.height = 24;
        local.wakes = "wakes".to_string();
        local.footer = "model".to_string();
        local.footer_right = "opus".to_string();
        let state = session.handle(&call("editor_state", json!([]))).expect("a state");
        assert_eq!(state["row"], 23);
        assert_eq!(state["status_row"], local.status_row());
        assert_eq!(state["footer_row"], local.footer_row());
        assert_eq!(state["out_bottom"], local.out_bottom());
        assert_eq!(state["wakes_row"], local.wakes_row());
        assert_eq!(state["session_row"], local.session_row());
        assert_eq!(state["bottom"], local.bottom());
        assert_eq!(state["menu_rows"], 0, "no slash menu on an empty draft");
        assert_eq!(state["draft"], "");

        // Keys, as bytes, and the actions they answer: typing then Enter submits the line.
        for byte in b"hello" {
            let answer = session.handle(&call("editor_key", json!([byte]))).expect("a key");
            assert_eq!(answer["kind"], "none");
        }
        let answer = session.handle(&call("editor_key", json!([13]))).expect("enter");
        assert_eq!(answer["kind"], "submit");
        assert_eq!(answer["text"], "hello");
        assert_eq!(session.handle(&call("editor_state", json!([]))).unwrap()["draft"], "");

        // The slash menu is the editor's, so it counts its own rows: a `/` opens it on the commands the
        // node handed over, and the status line moves up by that many rows.
        session.handle(&call("editor_key", json!([47]))).expect("slash");
        let menu = session.handle(&call("editor_state", json!([]))).expect("a state");
        assert_eq!(menu["menu_rows"], 1, "one command offered");
        let mut local = Editor::default();
        local.row = 23;
        local.width = 80;
        local.height = 24;
        local.wakes = "wakes".to_string();
        local.footer = "model".to_string();
        local.footer_right = "opus".to_string();
        local.commands = vec![Command { name: "/login".into(), args: false, hint: "sign in".into() }];
        local.feed(47);
        assert_eq!(menu["status_row"], local.status_row());

        // The frame: what the editor draws for its box, byte for byte, is what the wire carries.
        let answer = session.handle(&call("editor_render", json!([]))).expect("a frame");
        let bytes = proto::unbytes(answer["frame"].as_str().expect("a frame")).expect("base64");
        assert_eq!(String::from_utf8(bytes).expect("utf-8"), local.render());
    }

    #[test]
    fn a_length_a_key_byte_cannot_have_is_refused() {
        let mut session = Session::new();
        let failure = session.handle(&call("editor_key", json!([300]))).expect_err("a refusal");
        assert_eq!(failure.code, "term_bad_message");
        assert!(failure.message.contains("0..=255"), "{}", failure.message);
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
