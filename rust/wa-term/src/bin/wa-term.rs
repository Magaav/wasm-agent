//! `wa-term`: THE TERMINAL PROGRAM.
//!
//! A display-only change (the pinned request, the copy notice, the scrollbar) is built here and
//! installed here; the node is not rebuilt for it. It speaks `wa-term-proto` on stdin/stdout: one JSON
//! message per line, one message = one call the node makes on the transcript.
//!
//!   node -> program  {"v":1,"op":"hello","protocol":1,...}
//!   program -> node  {"v":1,"ok":{"protocol":1,"program":"wa-term"},"dirty":false}
//!   node -> program  {"v":1,"op":"call","method":"render","args":[100,30]}
//!   program -> node  {"v":1,"ok":{"frame":"<base64>"},"dirty":false}
//!
//! A program that speaks another protocol refuses AT THE HANDSHAKE, by name
//! (`term_protocol_mismatch`, both numbers in the message) and exits 2, so the node stops before it
//! draws anything. Everything this program writes to stderr is for a human; the node never parses it.

use std::io::{BufReader, BufWriter, Write};

use wa_term::session::Session;
use wa_term_proto as proto;

fn main() {
    let mut out = BufWriter::new(std::io::stdout());
    let mut input = BufReader::new(std::io::stdin());
    let mut reason = 0;

    match proto::recv(&mut input) {
        Ok(Some(message)) => match proto::parse_hello(&message) {
            Ok(hello) if hello.protocol == proto::PROTOCOL => {
                let _ = proto::send(&proto::hello_ok(), &mut out);
            }
            // A node that speaks another protocol is told OURS - never by an error message alone,
            // because the node must be able to name both numbers (`term_protocol_mismatch`).
            Ok(hello) => {
                eprintln!("{}: {}", proto::PROGRAM, proto::Failure::mismatch(hello.protocol));
                let _ = proto::send(&proto::hello_ok(), &mut out);
                reason = 2;
            }
            Err(failure) => { refuse(&failure, &mut out); reason = 2; }
        },
        // A node that closes the pipe before saying hello asked nothing of this program.
        Ok(None) => {}
        Err(failure) => { refuse(&failure, &mut out); reason = 2; }
    }

    if reason == 0 {
        let mut session = Session::new();
        loop {
            let message = match proto::recv(&mut input) {
                Ok(Some(message)) => message,
                Ok(None) => break,
                Err(failure) => { refuse(&failure, &mut out); reason = 2; break }
            };
            let answer = match proto::parse_call(&message) {
                Ok(call) => match session.handle(&call) {
                    Ok(value) => proto::ok(value, session.dirty()),
                    Err(failure) => proto::err(&failure),
                },
                Err(failure) => proto::err(&failure),
            };
            if proto::send(&answer, &mut out).is_err() { break }
        }
    }
    let _ = out.flush();
    if reason != 0 { std::process::exit(reason) }
}

/// Say what went wrong on stderr (a human's copy) and name it on the wire (the node's).
fn refuse(failure: &proto::Failure, out: &mut impl Write) {
    eprintln!("{PROGRAM}: {failure}", PROGRAM = proto::PROGRAM);
    let _ = proto::send(&proto::err(failure), out);
    let _ = out.flush();
}
