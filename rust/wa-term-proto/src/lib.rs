//! The versioned wire between the node and the terminal program.
//!
//! One message is ONE CALL the node already makes on `wa_term::transcript` - its method name, its
//! arguments and its return - never a dump of the transcript's private state. The method table is
//! `wa-term`'s own API, so a display-only change (the pinned row, the copy notice, the scrollbar)
//! adds no field to this file; a change to what the two sides SAY to each other adds a method and
//! bumps [`PROTOCOL`].
//!
//! Framing: one JSON object per line (ndjson) - requests on the program's stdin, replies on its
//! stdout. Byte payloads (a frame, marker JSON) travel base64, so a frame can hold anything,
//! including a newline, and the framing never has to escape.
//!
//! Every failure is a NAME, never a silent default:
//!
//! | name | when |
//! | --- | --- |
//! | `term_protocol_mismatch` | the program speaks a different [`PROTOCOL`]; both numbers are in the message |
//! | `term_program_missing` | no program at `WA_TERM_BIN`, beside the executable, or on `PATH`; the paths tried are in the message |
//! | `term_unknown_method` | the node called a method this program does not have (a newer node) |
//! | `term_call_failed` | the program died, or answered a line that is not a reply (the method and the line's head are in the message) |
//! | `term_bad_message` | a message that is not this protocol at all |
use std::io::{self, BufRead, Write};

use serde_json::{json, Value};

/// The wire this tree speaks. Bumped when a message's meaning changes; a program that answers another
/// number is refused by name at the handshake, before a single byte of the screen is drawn.
pub const PROTOCOL: u32 = 1;

/// The program's own name: the binary it is looked for as, and what it calls itself in the handshake.
pub const PROGRAM: &str = "wa-term";

/// The names a refusal carries (the table in this module's doc).
pub mod code {
    pub const PROTOCOL_MISMATCH: &str = "term_protocol_mismatch";
    pub const PROGRAM_MISSING: &str = "term_program_missing";
    pub const UNKNOWN_METHOD: &str = "term_unknown_method";
    pub const CALL_FAILED: &str = "term_call_failed";
    pub const BAD_MESSAGE: &str = "term_bad_message";
}

/// A refusal: what went wrong, by name, with the numbers/paths/method that say WHICH one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
    pub code: String,
    pub message: String,
}

impl Failure {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Failure { code: code.to_string(), message: message.into() }
    }
    pub fn mismatch(theirs: u32) -> Self {
        Self::new(code::PROTOCOL_MISMATCH, format!("this program speaks protocol {theirs}, the terminal speaks {PROTOCOL}"))
    }
    /// What a caller prints: the name first, so a report can quote it.
    pub fn line(&self) -> String { format!("{}: {}", self.code, self.message) }
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str(&self.line()) }
}

impl std::error::Error for Failure {}

/// The program's answer to the handshake.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hello {
    pub protocol: u32,
    pub program: String,
}

/// One call on the terminal's transcript: the method's name and its arguments, in order.
#[derive(Clone, Debug, PartialEq)]
pub struct Call {
    pub method: String,
    pub args: Vec<Value>,
}

/// One call's answer: its value and the transcript's `dirty` flag (the one piece of the program's
/// state the node gates frames on).
#[derive(Clone, Debug, PartialEq)]
pub struct Reply {
    pub value: Value,
    pub dirty: bool,
}

/// The first bytes of a line, for a refusal that has to quote it whole (a frame is kilobytes).
pub fn head(bytes: &str) -> String {
    let taken: String = bytes.chars().take(200).collect();
    if taken.len() < bytes.len() { format!("{taken}...") } else { taken }
}

/// The node's hello: the protocol it speaks and what it is.
pub fn hello() -> Value {
    json!({ "v": PROTOCOL, "op": "hello", "protocol": PROTOCOL, "program": "node" })
}

/// The program's answer to it.
pub fn hello_ok() -> Value {
    json!({ "v": PROTOCOL, "ok": { "protocol": PROTOCOL, "program": PROGRAM }, "dirty": false })
}

/// One call, as the node sends it.
pub fn call(method: &str, args: Value) -> Value {
    json!({ "v": PROTOCOL, "op": "call", "method": method, "args": args })
}

/// One answer, as the program sends it.
pub fn ok(value: Value, dirty: bool) -> Value {
    json!({ "v": PROTOCOL, "ok": value, "dirty": dirty })
}

/// One refusal, as either side sends it.
pub fn err(failure: &Failure) -> Value {
    json!({ "v": PROTOCOL, "err": { "code": failure.code, "message": failure.message } })
}

/// Write one message, one line, flushed: a call that sits in a pipe buffer is a frame that never
/// appeared.
pub fn send(message: &Value, to: &mut impl Write) -> io::Result<()> {
    let mut line = serde_json::to_vec(message).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))?;
    line.push(b'\n');
    to.write_all(&line)?;
    to.flush()
}

/// Read one message. `Ok(None)` is the other end closing its side - the program exiting, or the node.
pub fn recv(from: &mut impl BufRead) -> Result<Option<Value>, Failure> {
    let mut line = String::new();
    let read = from.read_line(&mut line).map_err(|error| Failure::new(code::CALL_FAILED, format!("reading a message failed: {error}")))?;
    if read == 0 { return Ok(None) }
    let line = line.trim_end_matches(['\n', '\r']);
    if line.is_empty() { return Ok(None) }
    serde_json::from_str(line).map(Some).map_err(|error| {
        Failure::new(code::CALL_FAILED, format!("a message that is not JSON ({error}): {}", head(line)))
    })
}

/// A hello, read from either side's shape: the node's is a request (`{"op":"hello","protocol":1}`)
/// and the program's is a reply (`{"ok":{"protocol":1}}`), and both are read here so a handshake
/// between two versions of this protocol can always be judged - including when the answer is the
/// refusal itself.
pub fn parse_hello(message: &Value) -> Result<Hello, Failure> {
    let body = message.get("ok").filter(|ok| ok.is_object()).unwrap_or(message);
    let protocol = body.get("protocol").and_then(Value::as_u64)
        .ok_or_else(|| Failure::new(code::BAD_MESSAGE, format!("hello without a protocol number: {}", head(&message.to_string()))))?;
    let program = body.get("program").and_then(Value::as_str).unwrap_or(PROGRAM).to_string();
    Ok(Hello { protocol: protocol as u32, program })
}

/// One call, as the program reads it.
pub fn parse_call(message: &Value) -> Result<Call, Failure> {
    let version = message.get("v").and_then(Value::as_u64).unwrap_or(0) as u32;
    if version != PROTOCOL {
        return Err(Failure::new(code::PROTOCOL_MISMATCH, format!("the terminal speaks protocol {version}, this program speaks {PROTOCOL}")));
    }
    if message.get("op").and_then(Value::as_str) != Some("call") {
        return Err(Failure::new(code::BAD_MESSAGE, format!("not a call: {}", head(&message.to_string()))));
    }
    let method = message.get("method").and_then(Value::as_str)
        .ok_or_else(|| Failure::new(code::BAD_MESSAGE, format!("a call without a method: {}", head(&message.to_string()))))?
        .to_string();
    let args = match message.get("args") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(args)) => args.clone(),
        Some(other) => return Err(Failure::new(code::BAD_MESSAGE, format!("args that are not a list: {}", head(&other.to_string())))),
    };
    Ok(Call { method, args })
}

/// One answer, as the node reads it: a value, or the failure the program named.
pub fn parse_reply(message: &Value) -> Result<Reply, Failure> {
    if let Some(error) = message.get("err") {
        let code = error.get("code").and_then(Value::as_str).unwrap_or(code::BAD_MESSAGE);
        let message = error.get("message").and_then(Value::as_str).unwrap_or("no message");
        return Err(Failure::new(code, message));
    }
    let version = message.get("v").and_then(Value::as_u64).unwrap_or(0) as u32;
    if version != PROTOCOL {
        return Err(Failure::new(code::PROTOCOL_MISMATCH, format!("the program speaks protocol {version}, this terminal speaks {PROTOCOL}")));
    }
    match message.get("ok") {
        Some(value) => Ok(Reply { value: value.clone(), dirty: message.get("dirty").and_then(Value::as_bool).unwrap_or(false) }),
        None => Err(Failure::new(code::BAD_MESSAGE, format!("a reply with neither ok nor err: {}", head(&message.to_string())))),
    }
}

/// Bytes on the wire: base64, so a frame's escape sequences and newlines are never the framing's
/// problem.
pub fn bytes(value: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(value)
}

pub fn unbytes(text: &str) -> Result<Vec<u8>, Failure> {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.decode(text)
        .map_err(|error| Failure::new(code::BAD_MESSAGE, format!("a payload that is not base64 ({error}): {}", head(text))))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(message: Value) -> Value {
        let mut bytes = Vec::new();
        send(&message, &mut bytes).expect("write");
        assert_eq!(bytes.last(), Some(&b'\n'), "one message is one line");
        let mut reader = io::BufReader::new(&bytes[..]);
        recv(&mut reader).expect("read").expect("a message")
    }

    #[test]
    fn a_call_survives_the_wire_with_its_arguments_in_order() {
        let message = roundtrip(call("render", json!([100, 30])));
        let call = parse_call(&message).expect("a call");
        assert_eq!(call.method, "render");
        assert_eq!(call.args, vec![json!(100), json!(30)]);
    }

    #[test]
    fn a_frame_travels_through_the_base64_and_comes_back_byte_for_byte() {
        let frame = "\x1b[1;1H\x1b[2Khello\nworld\x1b[0m";
        let message = roundtrip(ok(json!({ "frame": bytes(frame.as_bytes()) }), true));
        let reply = parse_reply(&message).expect("a reply");
        assert!(reply.dirty);
        let back = unbytes(reply.value["frame"].as_str().expect("frame")).expect("base64");
        assert_eq!(back, frame.as_bytes());
    }

    #[test]
    fn a_program_that_speaks_another_protocol_is_refused_by_name_with_both_numbers() {
        // A program one version ahead answers ITS hello: the number is the one it put in the reply.
        let mut other = hello_ok();
        other["ok"]["protocol"] = json!(2);
        other["v"] = json!(2);
        let hello = parse_hello(&other).expect("readable");
        assert_eq!(hello.protocol, 2, "the program's own number is what is read, not the node's");
        assert_eq!(Failure::mismatch(hello.protocol).code, "term_protocol_mismatch");
        assert!(Failure::mismatch(2).message.contains("protocol 2") && Failure::mismatch(2).message.contains("speaks 1"),
            "the message names both numbers: {}", Failure::mismatch(2).message);
        let older = json!({ "v": 3, "op": "call", "method": "write", "args": ["x"] });
        assert_eq!(parse_call(&older).unwrap_err().code, "term_protocol_mismatch");
        assert_eq!(parse_reply(&json!({ "v": 9, "ok": null })).unwrap_err().code, "term_protocol_mismatch");
    }

    #[test]
    fn a_line_that_is_not_a_reply_is_a_named_failure_that_quotes_it() {
        let mut reader = io::BufReader::new(&b"not json at all\n"[..]);
        let failure = recv(&mut reader).expect_err("a refusal");
        assert_eq!(failure.code, "term_call_failed");
        assert!(failure.message.contains("not json at all"), "{}", failure.message);
        assert_eq!(parse_reply(&json!({ "v": PROTOCOL, "nothing": 1 })).unwrap_err().code, "term_bad_message");
        let mut empty: &[u8] = b"";
        assert_eq!(recv(&mut io::BufReader::new(&mut empty)).expect("eof"), None, "a closed pipe is EOF, not an error");
    }

    #[test]
    fn a_hello_is_read_from_either_side_s_shape() {
        let from_the_node = parse_hello(&hello()).expect("the node's hello");
        assert_eq!((from_the_node.protocol, from_the_node.program.as_str()), (PROTOCOL, "node"));
        let from_the_program = parse_hello(&hello_ok()).expect("the program's hello");
        assert_eq!((from_the_program.protocol, from_the_program.program.as_str()), (PROTOCOL, PROGRAM));
        assert_eq!(parse_hello(&json!({"v":1,"ok":null})).unwrap_err().code, "term_bad_message");
    }

    #[test]
    fn a_refusal_from_the_program_keeps_its_own_name() {
        let failure = Failure::new(code::UNKNOWN_METHOD, "no method widgets");
        let reply = parse_reply(&roundtrip(err(&failure))).expect_err("a refusal");
        assert_eq!(reply, failure);
    }
}
