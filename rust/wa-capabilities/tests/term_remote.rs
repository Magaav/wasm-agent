//! THE TRANSCRIPT ACROSS THE WIRE: the same calls, the same screen bytes.
//!
//! The transcript lives in the terminal program (`rust/wa-term/src/bin/wa-term.rs`, its own process)
//! and the node speaks `wa-term-proto` to it (`rust/wa-capabilities/src/screen.rs`); there is no
//! in-process path any more. This file is the proof that the move changed WHERE the work happens and
//! nothing about what the reader sees:
//!
//! 1. ONE event log is driven through the handle attached to the REAL program binary - two real
//!    processes on this machine - and every answer, every row and every frame is compared byte for
//!    byte against `tests/golden/term_log.txt`, which the in-process `Transcript` recorded before
//!    the last slice deleted it. Not a stub: the binary is the one
//!    `cargo build -p wa-term --bin wa-term` makes.
//! 2. The refusals are named, not silent: a program that is not there (`term_program_missing`), one
//!    that speaks another protocol (`term_protocol_mismatch`, both numbers), one that dies mid-session
//!    (`term_call_failed`, and no frame is drawn from it afterwards).
//!
//! Why the test names the program instead of reading a variable: an environment set for the whole
//! test process is shared by every test in it, and a refusal test would race the equivalence one.
//! `Screen::remote_at` is the same path the console takes, with the lookup already answered.
//!
//! Run: `cargo test -p wa-capabilities --test term_remote` (build the program first:
//! names it; the test FAILS with the command rather than passing without a wire).
use std::io::Write;
use std::path::PathBuf;

use wa_capabilities::screen::Screen;

/// The terminal program's binary: beside this test's target directory (where
/// `cargo build -p wa-term --bin wa-term` puts it). A test that cannot find it FAILS: a comparison
/// without the wire proves nothing about the wire.
fn program() -> PathBuf {
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
    panic!("no wa-term program found (tried {}): build it with 'cargo build -p wa-term --bin wa-term'", tried.join(", "));
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
/// Take the scratch directory a fake program lived in away: a test that leaves files in /tmp is a test
/// the next run has to guess about.
#[cfg(unix)]
fn forget(program: &std::path::Path) {
    if let Some(dir) = program.parent() { let _ = std::fs::remove_dir_all(dir); }
}

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

/// THE GOLDEN IS THE DELETED PATH'S OWN OUTPUT.
///
/// `tests/golden/term_log.txt` was recorded by the in-process `Transcript` on 26/11, before the last
/// slice of `wa-term-own-program` deleted it: one event log - the chat, a notice, a pinned request, a
/// folded code block, 40 rows, bar hover/press/drag, a page, the bottom, a resize, a hold, a rewrite -
/// and every answer and frame it gave. The wire is compared against that file, answer for answer and
/// byte for byte, so the move is still judged by what it replaced (quality rule 14).
fn golden() -> Vec<String> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/golden/term_log.txt");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("the golden at {}: {error}", path.display()));
    text.lines().map(str::to_string).collect()
}

#[test]
fn the_wire_draws_the_golden_the_in_process_path_recorded() {
    let reference = golden();
    let mut remote = Screen::remote_at(program());
    assert!(remote.attach_error().is_none(), "the program answered the handshake");
    let across_the_wire = drive(&mut remote);

    assert_eq!(reference.len(), across_the_wire.len(), "the same log has the same length");
    for (step, (left, right)) in reference.iter().zip(across_the_wire.iter()).enumerate() {
        assert_eq!(left, right, "step {step} differs from the in-process path's recorded answer");
    }
    // A log of two empty strings would pass the comparison above and prove nothing.
    let frames: Vec<&String> = reference.iter().filter(|step| step.starts_with("frame") && step.len() > 400).collect();
    assert!(frames.len() >= 5, "the golden carries real frames ({} found)", frames.len());
    assert!(frames.iter().any(|frame| frame.contains("\\u{1b}[")), "a frame carries the escape sequences the tty needs");
    assert!(reference.iter().any(|step| step.starts_with("bar=Some")), "the long chat drew a scrollbar to compare");
}

#[cfg(unix)]
#[test]
fn the_input_box_answers_the_node_over_the_wire_with_its_own_geometry() {
    // The editor the node used to hold is now the program's: the node sets the state, sends the key
    // bytes and lays out from the numbers that come back. This drives the real binary through the
    // node's own client and requires the box it draws to be the editor's own frame.
    let mut screen = Screen::remote_at(program());
    assert!(screen.attach_error().is_none(), "the program answers the handshake");
    screen.editor_open();
    let setup = wa_capabilities::screen::EditorSetup {
        row: Some(23),
        width: Some(80),
        height: Some(24),
        status: Some(false),
        wakes: Some("wakes".into()),
        footer: Some("model".into()),
        footer_right: Some("opus".into()),
        commands: Some(vec![("/login".into(), false, "sign in".into())]),
        ..Default::default()
    };
    screen.editor_setup(&setup);
    let state = screen.editor_state();
    assert_eq!(state.row, 23);
    assert_eq!(state.width, 80);
    assert!(state.status_row < state.out_bottom.saturating_add(1), "the status line sits above the chat's bottom");
    assert_eq!(state.draft, "");

    // Keys: typed bytes answer none, Enter answers the line, and the draft is emptied by the submit.
    for byte in b"hello" {
        assert_eq!(screen.editor_key(*byte), wa_capabilities::screen::EditorAction::None);
    }
    assert_eq!(screen.editor_state().draft, "hello");
    assert_eq!(screen.editor_key(13), wa_capabilities::screen::EditorAction::Submit("hello".into()));
    assert_eq!(screen.editor_state().draft, "");

    // The frame is the editor's, not an empty string: the box draws its dividers.
    let frame = screen.editor_render();
    assert!(frame.len() > 40, "the box drew {} bytes", frame.len());
    assert!(frame.contains('\u{2500}') || frame.contains('-'), "the box has a divider");

    // The slash menu opens on the commands the node handed over, and it costs the chat a row.
    let before = screen.editor_state();
    assert_eq!(screen.editor_key(47), wa_capabilities::screen::EditorAction::None);
    let after = screen.editor_state();
    assert_eq!(after.menu_rows, 1, "one command offered");
    assert_eq!(after.out_bottom, before.out_bottom.saturating_sub(1));
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
    forget(&script);
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
    drop(screen);
    forget(&script);
}


