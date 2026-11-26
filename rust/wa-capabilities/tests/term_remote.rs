//! THE TRANSCRIPT ACROSS THE WIRE: the same calls, the same screen bytes.
//!
//! `WA_TERM_REMOTE=1` puts the transcript behind a boundary (`rust/wa-capabilities/src/screen.rs`): the
//! state and the painting live in the terminal program (`rust/wa-term/src/bin/wa-term.rs`, its own
//! process) and the node speaks `wa-term-proto` to it. This file is the proof that the move changed
//! WHERE the work happens and nothing about what the reader sees:
//!
//! 1. ONE event log is driven through both paths - a fresh `Screen::Local` (today's in-process
//!    `Transcript`) and a fresh `Screen::Remote` attached to the REAL program binary, two real
//!    processes on this machine - and every answer, every row and every frame is compared byte for
//!    byte. Not a stub: the binary is the one `cargo build -p wa-term --bin wa-term` makes.
//! 2. The refusals are named, not silent: a program that is not there (`term_program_missing`), one
//!    that speaks another protocol (`term_protocol_mismatch`, both numbers), one that dies mid-session
//!    (`term_call_failed`, and no frame is drawn from it afterwards), and a switch value the node does
//!    not know (`term_switch_invalid`).
//!
//! Why the test names the program instead of setting `WA_TERM_BIN`: an environment set for the whole
//! test process is shared by every test in it, and a refusal test would race the equivalence one.
//! `Screen::remote_at` is the same path the console takes, with the lookup already answered.
//!
//! Run: `cargo test -p wa-capabilities --test term_remote` (build the program first, or `WA_TERM_BIN`
//! names it; the test FAILS with the command rather than passing without a wire).
use std::io::Write;
use std::path::PathBuf;

use wa_capabilities::screen::Screen;

/// The terminal program's binary: `WA_TERM_BIN`, else beside this test's target directory (where
/// `cargo build -p wa-term --bin wa-term` puts it). A test that cannot find it FAILS: a comparison
/// without the wire proves nothing about the wire.
fn program() -> PathBuf {
    if let Some(named) = std::env::var_os("WA_TERM_BIN") {
        let path = PathBuf::from(named);
        assert!(path.is_file(), "WA_TERM_BIN={} is not a file", path.display());
        return path;
    }
    // The test binary's own directory is not one place (cargo puts this crate's under
    // target/<profile>/build/<crate>/<hash>/out when it has a build script), so every ancestor is
    // asked: the program lands beside `wa` in the profile directory, which one of them is.
    let exe = std::env::current_exe().expect("the test binary's path");
    let mut tried = Vec::new();
    for ancestor in exe.ancestors().skip(1).take(6) {
        let candidate = ancestor.join("wa-term");
        if candidate.is_file() { return candidate }
        tried.push(candidate.display().to_string());
    }
    panic!("no wa-term program found (tried {}): build it with 'cargo build -p wa-term --bin wa-term', or set WA_TERM_BIN", tried.join(", "));
}

/// A scratch directory outside the real `~/.wasm-agent`, refused when it would land inside it: the
/// fake programs this file writes are the only state it makes.
fn scratch(name: &str) -> PathBuf {
    let real = std::path::Path::new(&std::env::var("HOME").unwrap_or_default()).join(".wasm-agent");
    let base = ["/tmp", "/var/tmp"].into_iter().map(PathBuf::from)
        .find(|base| !base.starts_with(&real))
        .expect("a scratch root outside ~/.wasm-agent");
    let dir = base.join(format!("wa-term-remote-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    assert!(!dir.starts_with(&real), "refusing to run with state inside {}", real.display());
    dir
}

/// A fake terminal program: a shell script that answers in the protocol's own words.
#[cfg(unix)]
fn fake(name: &str, body: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = scratch(name).join("wa-term");
    let mut file = std::fs::File::create(&path).expect("write the fake program");
    file.write_all(format!("#!/bin/sh\n{body}\n").as_bytes()).expect("write");
    drop(file);
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    path
}

/// ONE event log, driven through a `Screen`: the chat, the notice row, the pinned request, the
/// scrollbar, a page, the pointer on the bar, a resize, and the frames each one draws. Every answer is
/// recorded, so a difference anywhere is a difference in the log.
fn drive(screen: &mut Screen) -> Vec<String> {
    let mut log: Vec<String> = Vec::new();
    let now = std::time::Instant::now;

    screen.set_scrollbar("auto");
    log.push(format!("dirty={}", screen.dirty()));
    log.push(format!("following={} bar_active={} last_is_code={}", screen.following(), screen.bar_active(), screen.last_is_code()));

    screen.block(false);
    screen.write("first answer, line one\nfirst answer, line two, long enough to wrap in a narrow window\n");
    screen.write_marked("please move the capability", true);
    log.push(format!("last_is_code={} dirty={}", screen.last_is_code(), screen.dirty()));
    log.push(format!("frame(60,12)={:?}", screen.render(60, 12)));
    log.push(format!("view(60,12)={:?}", screen.view(60, 12)));
    log.push(format!("text_width(60)={} topics={:?}", screen.text_width(60), screen.topics()));

    // The notice row, above the pinned request.
    screen.notice("Copied 12 characters", now(), false);
    log.push(format!("frame-notice={:?}", screen.render(60, 12)));
    log.push(format!("on_notice(1)={} on_pin(1)={} on_pin(2)={}", screen.on_notice(1), screen.on_pin(1), screen.on_pin(2)));
    log.push(format!("expire_notice-now={}", screen.expire_notice(now())));
    screen.clear_notice();
    log.push(format!("frame-after-notice={:?}", screen.render(60, 12)));

    // A code block, folded to one row, then a long chat that needs the bar.
    screen.code_block();
    screen.write("let answer = 42;\n");
    log.push(format!("fold_code={} last_is_code={}", screen.fold_code("a summary of the code"), screen.last_is_code()));
    // A collapsible topic (so `topics()` has one) and then a PLAIN block long enough that the chat
    // is taller than the window: the scrollbar is drawn from that, and both sides must draw it alike.
    screen.block(true);
    screen.write("a thinking line on its own topic\n");
    screen.write("another thinking line, still on that topic\n");
    screen.block(false);
    for n in 0..40 {
        screen.write(&format!("answer line {n}, with enough words on it to wrap past a sixty column window\n"));
    }
    log.push(format!("frame-long={:?}", screen.render(60, 12)));
    let bar = screen.bar();
    log.push(format!("bar={bar:?} bar_active={} text_width(60)={}", screen.bar_active(), screen.text_width(60)));

    // The pointer on the bar: hover, press, drag, release.
    log.push(format!("bar_hover={} bar_active={}", screen.bar_hover(5, 60, 60), screen.bar_active()));
    log.push(format!("bar_press={} bar_drag={} bar_release={}", screen.bar_press(5, 60, 60), screen.bar_drag(7), screen.bar_release()));
    log.push(format!("frame-after-drag={:?}", screen.render(60, 12)));
    log.push(format!("bar_frame(60)={:?}", screen.bar_frame(60)));

    // A page and the bottom: the view state the two sides have to agree on.
    screen.page(3);
    log.push(format!("following-after-page={} frame-page={:?}", screen.following(), screen.render(60, 12)));
    screen.page(-3);
    screen.to_bottom();
    screen.sync();
    log.push(format!("following-at-bottom={} frame-bottom={:?}", screen.following(), screen.render(60, 12)));

    // The pinned request and the topic navigation.
    log.push(format!("topics={:?} focus_prev={} focus_next={} pin_toggle={:?} pin_toggle={:?}",
        screen.topics(), screen.focus_prev(), screen.focus_next(), screen.pin_toggle(), screen.pin_toggle()));
    log.push(format!("jump_to_pinned={}", screen.jump_to_pinned(60)));
    log.push(format!("expand_at={} expand_hover={} copy_hover={} copy_at={:?}",
        screen.expand_at(2), screen.expand_hover(3), screen.copy_hover(4, 1), screen.copy_at(4, 1)));
    log.push(format!("frame-after-nav={:?}", screen.render(60, 12)));

    // A resize: the rows to draw are the node's decision, the wrapping is the program's.
    log.push(format!("frame(40,8)={:?}", screen.render(40, 8)));
    log.push(format!("frame(100,20)={:?}", screen.render(100, 20)));

    // The frame gate, exactly as the host runs it.
    screen.mark_dirty();
    log.push(format!("dirty-after-mark={} frame-gated={:?}", screen.dirty(), screen.render(100, 20)));
    screen.clean();
    log.push(format!("dirty-after-clean={}", screen.dirty()));

    // The replay hold, and a block whose head is rewritten in place.
    screen.hold();
    log.push(format!("head={} rewrite={}", screen.head("a head line"), screen.rewrite(0, "a rewritten head line")));
    log.push(format!("frame-after-rewrite={:?}", screen.render(60, 12)));

    log
}

#[test]
fn the_wire_draws_the_same_bytes_as_the_in_process_path() {
    let mut local = Screen::Local(wa_term::transcript::Transcript::default());
    let mut remote = Screen::remote_at(program());
    assert!(remote.attach_error().is_none(), "the program answered the handshake");

    let in_process = drive(&mut local);
    let across_the_wire = drive(&mut remote);

    assert_eq!(in_process.len(), across_the_wire.len(), "the same log has the same length");
    for (step, (left, right)) in in_process.iter().zip(across_the_wire.iter()).enumerate() {
        assert_eq!(left, right, "step {step} differs between the in-process path and the terminal program");
    }
    // A log of two empty strings would pass the comparison above and prove nothing.
    let frames: Vec<&String> = in_process.iter().filter(|step| step.starts_with("frame") && step.len() > 400).collect();
    assert!(frames.len() >= 5, "the log carries real frames ({} found)", frames.len());
    assert!(frames.iter().any(|frame| frame.contains("\\u{1b}[")), "a frame carries the escape sequences the tty needs");
    assert!(in_process.iter().any(|step| step.starts_with("bar=Some")), "the long chat drew a scrollbar to compare");
}

#[cfg(unix)]
#[test]
fn a_missing_program_is_refused_by_name_and_names_the_path() {
    let mut screen = Screen::remote_at("/nonexistent/wa-term-program");
    let failure = screen.attach_error().expect("a refusal");
    assert_eq!(failure.code, "term_program_missing");
    assert!(failure.message.contains("/nonexistent/wa-term-program"), "{}", failure.message);
    assert_eq!(screen.render(40, 10), "", "nothing is drawn without a program");
}

#[cfg(unix)]
#[test]
fn a_program_that_speaks_another_protocol_is_refused_by_name_with_both_numbers() {
    let script = fake("mismatch", r#"printf '{"v":2,"ok":{"protocol":2,"program":"wa-term"},"dirty":false}\n'"#);
    let mut screen = Screen::remote_at(&script);
    let failure = screen.attach_error().expect("a refusal");
    assert_eq!(failure.code, "term_protocol_mismatch");
    assert!(failure.message.contains("protocol 2") && failure.message.contains("speaks 1"), "both numbers: {}", failure.message);
}

#[cfg(unix)]
#[test]
fn a_program_that_dies_mid_session_is_a_named_failure_and_never_a_stale_frame() {
    // Answers the handshake, then exits: the next call has nowhere to go.
    let script = fake("dies", r#"read line; printf '{"v":1,"ok":{"protocol":1,"program":"wa-term"},"dirty":false}\n'"#);
    let mut screen = Screen::remote_at(&script);
    assert!(screen.attach_error().is_none(), "the handshake answered");
    screen.write("a line nobody will draw");
    assert_eq!(screen.render(40, 10), "", "a dead program draws nothing");
    let failure = screen.attach_error().expect("the failure sticks");
    assert_eq!(failure.code, "term_call_failed");
    assert_eq!(screen.render(40, 10), "", "and a later frame still draws nothing");
}

#[test]
fn the_switch_refuses_a_value_it_does_not_know() {
    // One test touches the process's environment, and it puts it back: nothing else in this file
    // reads it, because the others name their program with `Screen::remote_at`.
    std::env::set_var("WA_TERM_REMOTE", "banana");
    let mut screen = Screen::for_console();
    std::env::remove_var("WA_TERM_REMOTE");
    let failure = screen.attach_error().expect("a refusal");
    assert_eq!(failure.code, "term_switch_invalid");
    assert!(failure.message.contains("banana"), "{}", failure.message);
    // And the default: unset, and 0, are today's in-process path.
    assert!(matches!(Screen::for_console(), Screen::Local(_)), "unset is the in-process path");
    std::env::set_var("WA_TERM_REMOTE", "0");
    let as_zero = matches!(Screen::for_console(), Screen::Local(_));
    std::env::remove_var("WA_TERM_REMOTE");
    assert!(as_zero, "0 is the in-process path");
}
