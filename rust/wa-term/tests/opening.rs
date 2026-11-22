//! The opening, measured in a real pty: the bytes it writes, and the screen it leaves behind.
//!
//! Victor's own test of it ("open a new foot window and run `wa chat`: green rain, a supernova, it falls
//! into a green star, the title decodes, and the usual header is there") cannot be a unit test: the
//! animation lives in the reader thread of a process with a console, and its promise is about the SCREEN
//! a terminal ends up holding. So this drives the real binary in a pty and reads that screen back through
//! the terminal in memory the render tests use (`wa_term::scroll::vt::Vt`) - the bytes say where the cursor
//! was told to go, and only a terminal can say what ended up there.
//!
//! What it asserts, and each one refuses rather than passes when it cannot tell:
//!   1. with the opening on, the bytes hold the alternate screen, glyph frames and the star, and the
//!      FINAL screen equals the final screen of the same start with the opening off - the promise that
//!      nothing is left over and no scrollback moved;
//!   2. a key typed 100 ms in is in the draft, and it ends the opening at once (the header is up before
//!      the animation's own 2 s would have been) and leaves the same screen as (1) plus that draft;
//!   3. `WASM_AGENT_CLI_OPENING=off`, `NO_COLOR`, a resumed session (`--session <id>`) and a pipe each
//!      write ZERO animation frames;
//!
//! Isolation: its own scratch HOME under the temp root, and it REFUSES to run against the operator's own
//! ~/.wasm-agent (a test that reads or writes the real node's state is not a test). No network, no fleet.
//!
//! The binary comes from `WA_BIN` (what `scripts/test.sh` hands the rows that must run the tree's binary).
//! Without it this row says SKIP and passes: it cannot tell, and it does not pretend.
#![cfg(unix)]

use std::os::unix::io::FromRawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use wa_term::opening::ALIEN;
use wa_term::scroll::vt::Vt;

const COLUMNS: usize = 100;
const ROWS: usize = 30;

fn binary() -> Option<PathBuf> {
    let asked = std::env::var("WA_BIN").or_else(|_| std::env::var("WA_FAST_BIN")).ok()?;
    let path = PathBuf::from(asked);
    if !path.is_file() { return None; }
    Some(path)
}

/// A scratch root that is NOT the operator's own state: `/tmp` when TMPDIR points inside
/// `~/.wasm-agent` (it does on this node), and a refusal - not a pass - when no such root exists.
fn scratch(tag: &str) -> PathBuf {
    let real = PathBuf::from(format!("{}/.wasm-agent", std::env::var("HOME").unwrap_or_default()));
    for base in [std::env::temp_dir(), PathBuf::from("/tmp"), PathBuf::from("/var/tmp")] {
        if base.starts_with(&real) { continue; }
        let dir = base.join(format!("wa-opening-{}-{}", tag, std::process::id()));
        std::fs::create_dir_all(&dir).expect("a scratch directory");
        return dir;
    }
    panic!("no scratch root outside {}: refusing to run", real.display());
}

/// One chat in a pty: the master side (what it wrote) and the child.
struct Pty {
    master: i32,
    child: Child,
    bytes: Vec<u8>,
    /// When each read arrived, so a test can say WHEN a sequence was written and not only that it was
    /// ("the key ended the opening at once" is a statement about time, not about bytes).
    marks: Vec<(Instant, usize)>,
}

impl Pty {
    /// Start `wa chat` with `env` on a `COLUMNS` x `ROWS` pty. The child gets the slave as its stdin and
    /// stdout and its own session with the slave as the controlling terminal, which is what makes
    /// `isatty` and the raw editor behave the way they do in a terminal.
    fn spawn(bin: &Path, dir: &Path, env: &[(&str, &str)], args: &[&str]) -> Pty {
        let mut winsize = libc::winsize { ws_row: ROWS as u16, ws_col: COLUMNS as u16, ws_xpixel: 0, ws_ypixel: 0 };
        let mut master: libc::c_int = -1;
        let mut slave: libc::c_int = -1;
        let opened = unsafe {
            libc::openpty(&mut master, &mut slave, std::ptr::null_mut(), std::ptr::null(), &mut winsize)
        };
        assert_eq!(opened, 0, "the pty opened");
        let stdin = unsafe { Stdio::from_raw_fd(libc::dup(slave)) };
        let stdout = unsafe { Stdio::from_raw_fd(libc::dup(slave)) };
        let mut command = Command::new(bin);
        // env_clear: an allow-list, not this machine's environment. Without it the test inherited the
        // operator's provider, vault and relay variables, and the screen it compared held a model this
        // test never configured (measured: `deepseek-v4.1-flash @ http://127.0.0.1:8810/...` on a scratch
        // home that has no provider at all).
        command.args(args).stdin(stdin).stdout(stdout).stderr(Stdio::null()).current_dir(dir).env_clear();
        for (key, value) in env { command.env(key, value); }
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 { return Err(std::io::Error::last_os_error()); }
                if libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 { return Err(std::io::Error::last_os_error()); }
                Ok(())
            });
        }
        let child = command.spawn().expect("the binary starts");
        unsafe { libc::close(slave); }
        // Non-blocking reads: the frames arrive while the test is looking away, and a blocking read would
        // sit on the last one.
        let flags = unsafe { libc::fcntl(master, libc::F_GETFL) };
        unsafe { libc::fcntl(master, libc::F_SETFL, flags | libc::O_NONBLOCK); }
        Pty { master, child, bytes: Vec::new(), marks: Vec::new() }
    }

    /// Read whatever the chat has written, until `done` is true of everything so far or `timeout` passes.
    /// Answers whether `done` became true.
    fn read_until(&mut self, timeout: Duration, done: impl Fn(&[u8]) -> bool) -> bool {
        let deadline = Instant::now() + timeout;
        let mut buffer = [0u8; 8192];
        loop {
            if done(&self.bytes) { return true; }
            if Instant::now() >= deadline { return done(&self.bytes); }
            let read = unsafe { libc::read(self.master, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
            if read > 0 {
                self.bytes.extend_from_slice(&buffer[..read as usize]);
                self.marks.push((Instant::now(), self.bytes.len()));
                continue;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// Read until nothing new has arrived for `quiet` (or `cap` passes): a start that has stopped writing
    /// has finished it, whatever it drew. The alternative - waiting for one particular row - turns a
    /// changed footer into a thirty-second timeout.
    fn read_quiet(&mut self, quiet: Duration, cap: Duration) {
        let deadline = Instant::now() + cap;
        let mut last = Instant::now();
        let mut seen = self.bytes.len();
        let mut buffer = [0u8; 8192];
        while Instant::now() < deadline {
            let read = unsafe { libc::read(self.master, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
            if read > 0 {
                self.bytes.extend_from_slice(&buffer[..read as usize]);
                self.marks.push((Instant::now(), self.bytes.len()));
                seen = self.bytes.len();
                last = Instant::now();
                continue;
            }
            if self.bytes.len() == seen && last.elapsed() >= quiet { return; }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// When the first occurrence of `needle` was READ from the pty: the read it arrived in, to the
    /// millisecond the frame budget is about.
    fn when(&self, needle: &str) -> Option<Instant> {
        let text = String::from_utf8_lossy(&self.bytes).to_string();
        let at = text.find(needle)?;
        // The offset in the lossy text and in the bytes is the same for ASCII needles.
        self.marks.iter().find(|(_, len)| *len > at).map(|(when, _)| *when)
    }

    /// The window changed size: the ioctl a terminal's own resize does, which is what sends SIGWINCH to
    /// the chat. The host reads the new size from the console, so this is the whole of the event.
    fn resize(&mut self, columns: u16, rows: u16) {
        let mut winsize = libc::winsize { ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0 };
        let moved = unsafe { libc::ioctl(self.master, libc::TIOCSWINSZ as _, &mut winsize) };
        assert_eq!(moved, 0, "the window resized");
    }

    fn write(&mut self, text: &str) {
        let bytes = text.as_bytes();
        let mut sent = 0;
        while sent < bytes.len() {
            let wrote = unsafe { libc::write(self.master, bytes[sent..].as_ptr() as *const libc::c_void, bytes.len() - sent) };
            if wrote > 0 { sent += wrote as usize; } else { std::thread::sleep(Duration::from_millis(5)); }
        }
    }

    /// The screen those bytes leave, read through the render tests' terminal in memory.
    fn screen(&self) -> Vt {
        let mut vt = Vt::new(COLUMNS, ROWS);
        vt.feed(&self.bytes);
        vt
    }

    fn stop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        unsafe { libc::close(self.master); }
    }
}

/// The environment of every run: an allow-list (no vault, no relay, no provider), a scratch home, and a
/// rendezvous that goes nowhere - nothing here can reach a real node.
fn environment(home: &Path, db: &Path) -> Vec<(String, String)> {
    vec![
        ("PATH".into(), "/usr/bin:/bin".into()),
        ("HOME".into(), home.display().to_string()),
        ("TERM".into(), "xterm-256color".into()),
        ("LANG".into(), "C.UTF-8".into()),
        ("WASM_AGENT_HOME".into(), home.display().to_string()),
        ("WASM_AGENT_LUA_ROOT".into(), lua_root()),
        ("WASM_AGENT_RENDEZVOUS".into(), "http://127.0.0.1:9".into()),
        ("WASM_AGENT_RELAY".into(), String::new()),
        ("WASM_AGENT_MANAGED".into(), "0".into()),
        ("WA_SKIP_UPDATE_CHECK".into(), "1".into()),
        ("COLUMNS".into(), COLUMNS.to_string()),
        ("LINES".into(), ROWS.to_string()),
        ("WA_OPENING_MS".into(), "700".into()),
        ("LEDGER".into(), db.display().to_string()),
    ]
}

fn lua_root() -> String {
    std::env::var("WASM_AGENT_LUA_ROOT").unwrap_or_else(|_| {
        Path::new(env!("CARGO_MANIFEST_DIR")).parent().and_then(|rust| rust.parent())
            .map(|root| root.display().to_string()).unwrap_or_default()
    })
}

fn pairs(env: &[(String, String)]) -> Vec<(&str, &str)> {
    env.iter().map(|(key, value)| (key.as_str(), value.as_str())).collect()
}

/// The prompt on screen: the footer the chat draws under the input box, and the welcome line above it.
/// Both, because the opening paints the welcome line on the alternate screen too - the footer is what
/// only the chat's own finished start writes.
fn started(bytes: &[u8]) -> bool {
    let text = String::from_utf8_lossy(bytes);
    text.contains("/ for commands") && text.contains("Warning") == false
}

/// A session id is the one thing two starts cannot share; it is the same 36 characters in the same row, so
/// the screens are compared with the ids blanked rather than with the whole row dropped.
fn normalise(rows: &[String]) -> Vec<String> {
    rows.iter().map(|row| {
        let chars: Vec<char> = row.chars().collect();
        let mut out = String::new();
        let mut at = 0;
        while at < chars.len() {
            if at + 36 <= chars.len() {
                let window: String = chars[at..at + 36].iter().collect();
                let uuid = window.char_indices().all(|(index, ch)| {
                    if [8, 13, 18, 23].contains(&index) { ch == '-' } else { ch.is_ascii_hexdigit() }
                });
                if uuid { out.push_str("<session>"); at += 36; continue; }
            }
            out.push(chars[at]);
            at += 1;
        }
        // The welcome line names the BUILDs (`✻ Welcome to wasm-agent! v1.0 · v<commit>`), and two binaries
        // cannot carry the same commit: everything after the product's `!` is blanked, not dropped - so
        // the product version is still compared, and only the build's own label is not.
        let mut text = out.trim_end().to_string();
        if let Some(at) = text.find("Welcome to wasm-agent!") {
            let start = at + "Welcome to wasm-agent!".len();
            text.replace_range(start..text.len(), " <versions>");
        }
        // The dot's spacing is one of the two strings this change edits (one space on each side, Victor
        // 22/11): a row is compared with it collapsed, which is what lets the base binary's two spaces
        // and this tree's one be the same screen for every check that is not about that string.
        let chars: Vec<char> = text.chars().collect();
        let mut collapsed = String::new();
        let mut at = 0;
        while at < chars.len() {
            if chars[at] == '\u{b7}' {
                while collapsed.ends_with(' ') { collapsed.pop(); }
                let mut next = at + 1;
                while next < chars.len() && chars[next] == ' ' { next += 1; }
                collapsed.push_str(" \u{b7} ");
                at = next;
                continue;
            }
            collapsed.push(chars[at]);
            at += 1;
        }
        collapsed
    }).collect()
}

fn row_with(rows: &[String], needle: &str) -> String {
    rows.iter().find(|row| row.contains(needle)).cloned().unwrap_or_default()
}

/// The frames of the opening: the alternate screen entered, and the cursor-addressed rows the rain is
/// drawn with. Zero of either means the animation did not run.
fn animation_frames(bytes: &[u8]) -> usize {
    let text = String::from_utf8_lossy(bytes);
    if !text.contains("\u{1b}[?1049h") { return 0; }
    text.match_indices("\u{1b}[").filter(|(at, _)| {
        let rest = &text[at + 2..];
        rest.chars().take_while(|ch| ch.is_ascii_digit() || *ch == ';').count() > 1
            && rest.chars().skip_while(|ch| ch.is_ascii_digit() || *ch == ';').next() == Some('H')
    }).count()
}

#[test]
fn the_opening_plays_and_leaves_the_screen_a_start_without_it_leaves() {
    let Some(bin) = binary() else {
        eprintln!("SKIP opening: no wa binary (WA_BIN); this row reads a real pty and cannot tell without one");
        return;
    };
    let dir = scratch("play");
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let db = dir.join("ledger.db");
    let env = environment(&home, &db);
    let args = vec!["--db", db.to_str().unwrap(), "chat"];

    let mut with = Pty::spawn(&bin, &dir, &pairs(&env), &args);
    let played = with.read_until(Duration::from_secs(30), |bytes| {
        animation_frames(bytes) > 10 && started(bytes)
    });
    // The frame the opening ends on is the header; the chat's own start writes the same picture right
    // after, so a quiet moment is enough for the main screen to be whole.
    with.read_until(Duration::from_millis(600), |_| false);
    let with_screen = normalise(&with.screen().rows());
    let with_bytes = with.bytes.clone();
    with.stop();

    let mut without_env = env.clone();
    without_env.push(("WASM_AGENT_CLI_OPENING".into(), "off".into()));
    let mut without = Pty::spawn(&bin, &dir, &pairs(&without_env), &args);
    without.read_until(Duration::from_secs(30), |bytes| started(bytes));
    without.read_until(Duration::from_millis(600), |_| false);
    let without_screen = normalise(&without.screen().rows());
    let without_frames = animation_frames(&without.bytes);
    without.stop();

    assert!(played, "the opening played and the start finished: {} frames", animation_frames(&with_bytes));

    // PARITY WITH THE CODE THIS REPLACES (rule 14), when the gate hands over a base binary: the screen
    // a start leaves with the opening OFF is the screen the base's own binary leaves - the same bytes, in
    // the same order, not merely the same picture as this build draws without it.
    if let Some(base) = std::env::var("WA_BASE_BIN").ok().map(PathBuf::from).filter(|path| path.is_file()) {
        let mut original = Pty::spawn(&base, &dir, &pairs(&env), &args);
        original.read_quiet(Duration::from_millis(800), Duration::from_secs(20));
        let base_screen = normalise(&original.screen().rows());
        original.stop();
        assert_eq!(without_screen, base_screen,
            "opening = off writes the screen the base binary writes:
--- this tree, off ---
{}
--- base ---
{}",
            without_screen.join("
"), base_screen.join("
"));
    }
    assert_eq!(without_frames, 0, "opening = off writes no animation frame at all");
    let text = String::from_utf8_lossy(&with_bytes).to_string();
    assert!(text.contains("\u{1b}[?1049l"), "and it gives the reader's own screen back: {:?}",
        text.get(text.len().saturating_sub(80)..));
    let glyphs = ALIEN.iter().filter(|glyph| text.contains(**glyph)).count();
    assert!(glyphs >= 8, "the frames are the alien alphabet, not noise: {glyphs} of 26 glyphs appeared");
    assert!(row_with(&with_screen, "Welcome to wasm-agent!") != "", "the finished screen holds the header");
    assert_eq!(with_screen, without_screen,
        "the screen the opening leaves is the screen a start without it leaves:\n--- with ---\n{}\n--- without ---\n{}",
        with_screen.join("\n"), without_screen.join("\n"));
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn a_key_during_the_opening_is_in_the_draft_and_ends_it() {
    let Some(bin) = binary() else {
        eprintln!("SKIP opening key: no wa binary (WA_BIN)");
        return;
    };
    let dir = scratch("key");
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let db = dir.join("ledger.db");
    let env = environment(&home, &db);
    let args = vec!["--db", db.to_str().unwrap(), "chat"];

    // (a) A key while the animation IS playing, which is Victor's own test: "run it again and press a
    // key at once: the animation stops and your key is in the input".
    let mut pty = Pty::spawn(&bin, &dir, &pairs(&env), &args);
    let playing = pty.read_until(Duration::from_secs(30), |bytes| {
        String::from_utf8_lossy(bytes).contains("\u{1b}[?1049h")
    });
    assert!(playing, "the opening is playing before the key is sent");
    let typed_at = Instant::now();
    pty.write("k");
    let ended = pty.read_until(Duration::from_secs(10), |bytes| {
        String::from_utf8_lossy(bytes).contains("\u{1b}[?1049l")
    });
    let ended_ms = typed_at.elapsed().as_millis();
    pty.read_quiet(Duration::from_millis(500), Duration::from_secs(5));
    let screen = normalise(&pty.screen().rows());
    let draft = row_with(&screen, "\u{276f}");
    pty.stop();

    assert!(ended, "the key ends the opening: the alternate screen is left");
    assert!(ended_ms < 1500, "and at once, not at the animation's own end: {ended_ms} ms after the key");
    assert!(draft.contains('k'), "the key is in the draft, not lost: {draft:?}");
    assert!(row_with(&screen, "Welcome to wasm-agent!") != "", "with the header drawn behind it");

    // (b) A key 100 ms after the process starts - before the animation's own first frame, because the
    // interpreter is still opening the ledger. It must not be lost either: it is in the draft, and the
    // start it interrupted is the ordinary one.
    let mut pty = Pty::spawn(&bin, &dir, &pairs(&env), &args);
    std::thread::sleep(Duration::from_millis(100));
    pty.write("k");
    pty.read_quiet(Duration::from_millis(700), Duration::from_secs(20));
    let screen = normalise(&pty.screen().rows());
    let draft = row_with(&screen, "\u{276f}");
    let opened = pty.when("\u{1b}[?1049h");
    let left = pty.when("\u{1b}[?1049l");
    pty.stop();
    assert!(draft.contains('k'), "a key typed 100 ms in is in the draft: {draft:?}");
    assert!(row_with(&screen, "Welcome to wasm-agent!") != "", "and the header is up");
    if let (Some(opened), Some(left)) = (opened, left) {
        let played = left.saturating_duration_since(opened).as_millis();
        assert!(played < 400, "and it did not sit through the animation it interrupted: {played} ms of it played");
    }
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn a_resize_ends_the_opening() {
    let Some(bin) = binary() else {
        eprintln!("SKIP opening resize: no wa binary (WA_BIN)");
        return;
    };
    let dir = scratch("resize");
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let db = dir.join("ledger.db");
    let env = environment(&home, &db);
    let args = vec!["--db", db.to_str().unwrap(), "chat"];

    let mut pty = Pty::spawn(&bin, &dir, &pairs(&env), &args);
    let playing = pty.read_until(Duration::from_secs(30), |bytes| {
        String::from_utf8_lossy(bytes).contains("\u{1b}[?1049h")
    });
    assert!(playing, "the opening is playing before the window changes");
    let resized_at = Instant::now();
    pty.resize(80, 20);
    let ended = pty.read_until(Duration::from_secs(10), |bytes| {
        String::from_utf8_lossy(bytes).contains("\u{1b}[?1049l")
    });
    let ended_ms = resized_at.elapsed().as_millis();
    pty.read_quiet(Duration::from_millis(500), Duration::from_secs(5));
    let screen = normalise(&pty.screen().rows());
    pty.stop();
    std::fs::remove_dir_all(&dir).ok();

    assert!(ended, "a resize ends the opening rather than leaving a frame for a width the window has not");
    assert!(ended_ms < 1500, "and at once: {ended_ms} ms after the resize");
    assert!(row_with(&screen, "Welcome to wasm-agent!") != "", "with the header drawn at the new size");
}

#[test]
fn the_setting_no_color_a_resumed_session_and_a_pipe_write_no_animation() {
    let Some(bin) = binary() else {
        eprintln!("SKIP opening off-switches: no wa binary (WA_BIN)");
        return;
    };
    let dir = scratch("off");
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let db = dir.join("ledger.db");
    let base = environment(&home, &db);
    let args = vec!["--db", db.to_str().unwrap(), "chat"];

    let cases: Vec<(&str, Option<(&str, &str)>, &[&str])> = vec![
        ("WASM_AGENT_CLI_OPENING=off", Some(("WASM_AGENT_CLI_OPENING", "off")), &[]),
        ("NO_COLOR", Some(("NO_COLOR", "1")), &[]),
        ("a resumed session", None, &["--session", "11111111-2222-3333-4444-555555555555"]),
        ("a message argument", None, &["hello"]),
    ];
    for (label, variable, extra) in cases {
        let mut env = base.clone();
        if let Some((key, value)) = variable { env.push((key.into(), value.into())); }
        let mut argv: Vec<&str> = args.clone();
        argv.extend_from_slice(extra);
        let mut pty = Pty::spawn(&bin, &dir, &pairs(&env), &argv);
        pty.read_quiet(Duration::from_millis(800), Duration::from_secs(15));
        let frames = animation_frames(&pty.bytes);
        let text = String::from_utf8_lossy(&pty.bytes).to_string();
        pty.stop();
        assert_eq!(frames, 0, "{label}: no animation frame may be written (saw {frames})");
        assert!(!text.contains("\u{1b}[?1049h"), "{label}: the alternate screen is never taken");
    }

    // A pipe: no console, so nothing to animate on. The output is the plain transcript.
    let mut child = Command::new(&bin)
        .args(["--db", db.to_str().unwrap(), "chat"])
        .env_clear()
        .envs(environment(&home, &db).into_iter())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("the binary starts on a pipe");
    let mut piped = Vec::new();
    if let Some(mut stdout) = child.stdout.take() {
        let _ = std::io::copy(&mut stdout, &mut piped);
    }
    let _ = child.wait();
    let text = String::from_utf8_lossy(&piped).to_string();
    assert!(!text.contains("\u{1b}[?1049h"), "a pipe: the alternate screen is never taken");
    assert_eq!(animation_frames(&piped), 0, "a pipe: no animation frame");
    assert!(text.is_empty() || !text.contains("Welcome to wasm-agent"),
        "a piped chat is a transcript, not a screen: {:?}", &text[..text.len().min(200)]);
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn the_window_too_small_for_the_box_gets_no_opening() {
    let Some(bin) = binary() else {
        eprintln!("SKIP opening small window: no wa binary (WA_BIN)");
        return;
    };
    let dir = scratch("small");
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let db = dir.join("ledger.db");
    let env = environment(&home, &db);
    let args = vec!["--db", db.to_str().unwrap(), "chat"];

    // 50x12: under Victor's floor of 60x14, and under the rows the input box needs anyway.
    let mut winsize = libc::winsize { ws_row: 12, ws_col: 50, ws_xpixel: 0, ws_ypixel: 0 };
    let mut master: libc::c_int = -1;
    let mut slave: libc::c_int = -1;
    let opened = unsafe { libc::openpty(&mut master, &mut slave, std::ptr::null_mut(), std::ptr::null(), &mut winsize) };
    assert_eq!(opened, 0);
    let stdin = unsafe { Stdio::from_raw_fd(libc::dup(slave)) };
    let stdout = unsafe { Stdio::from_raw_fd(libc::dup(slave)) };
    let mut command = Command::new(&bin);
    command.args(&args).stdin(stdin).stdout(stdout).stderr(Stdio::null()).current_dir(&dir).env_clear();
    for (key, value) in pairs(&env) { command.env(key, value); }
    unsafe { command.pre_exec(|| { libc::setsid(); Ok(()) }); }
    let mut child = command.spawn().expect("starts");
    unsafe { libc::close(slave); }
    let flags = unsafe { libc::fcntl(master, libc::F_GETFL) };
    unsafe { libc::fcntl(master, libc::F_SETFL, flags | libc::O_NONBLOCK); }
    let mut bytes = Vec::new();
    let deadline = Instant::now() + Duration::from_millis(2500);
    let mut buffer = [0u8; 8192];
    while Instant::now() < deadline {
        let read = unsafe { libc::read(master, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
        if read > 0 { bytes.extend_from_slice(&buffer[..read as usize]); } else { std::thread::sleep(Duration::from_millis(5)); }
    }
    let _ = child.kill();
    let _ = child.wait();
    unsafe { libc::close(master); }
    std::fs::remove_dir_all(&dir).ok();
    let text = String::from_utf8_lossy(&bytes).to_string();
    assert_eq!(animation_frames(&bytes), 0, "a window under 60x14 has no opening");
    assert!(!text.contains("\u{1b}[?1049h"), "and never takes the alternate screen");
}
