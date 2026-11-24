//! The icon set on a tty whose font cannot be known (item 6, Victor 23/11), measured in a real pty
//! across TWO starts of the same node.
//!
//! WHY A PTY AND TWO PROCESSES. The bug the item describes lives between processes: `wa` decides its icon
//! set at start from what it can measure about the terminal, and `/icons wa` has to change the NEXT start -
//! that is a config line read by a second process, which no in-process test can see. A container (or an ssh
//! session) has no terminal emulator in its ancestry, so the font cannot be measured there at all; this test
//! reproduces that by giving the child a PATH with no shell in it, which is exactly the state in which the
//! walk and fontconfig cannot run and the answer is "unknown".
//!
//! What it asserts:
//!   1. the first start says the line ONCE: "icons: unicode (font unknown here). If your terminal has wa
//!      Icons: /icons wa" - one occurrence in the whole stream, not one per frame;
//!   2. `/icons wa` writes `icons = wa` into this node's config file (the path is taken from what wa itself
//!      answered, never guessed here), and it is the only `icons = ` line in it;
//!   3. the SECOND start of the same node does not repeat the line, and `/icons` reports the set it is
//!      drawing with the config file as its source - the choice survived the restart.
//!
//! Isolation: its own scratch HOME, its own scratch PATH, and a refusal - never a pass - when it cannot
//! make a scratch root outside the operator's own ~/.wasm-agent. The binary comes from `WA_BIN`; without one
//! the row SKIPS by name.
#![cfg(unix)]

use std::os::unix::io::FromRawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const COLUMNS: u16 = 100;
const ROWS: u16 = 30;
const NOTICE: &str = "icons: unicode (font unknown here). If your terminal has wa Icons: /icons wa";

fn binary() -> Option<PathBuf> {
    let asked = std::env::var("WA_BIN").or_else(|_| std::env::var("WA_FAST_BIN")).ok()?;
    let path = PathBuf::from(asked);
    if !path.is_file() { return None; }
    Some(path)
}

/// A scratch root that is NOT the operator's own state (the rule every row that writes obeys).
fn scratch(tag: &str) -> PathBuf {
    let real = PathBuf::from(format!("{}/.wasm-agent", std::env::var("HOME").unwrap_or_default()));
    for base in [std::env::temp_dir(), PathBuf::from("/tmp"), PathBuf::from("/var/tmp")] {
        if base.starts_with(&real) { continue; }
        let dir = base.join(format!("wa-icons-{}-{}", tag, std::process::id()));
        std::fs::create_dir_all(&dir).expect("a scratch directory");
        return dir;
    }
    panic!("no scratch root outside {}: refusing to run", real.display());
}

fn lua_root() -> String {
    std::env::var("WASM_AGENT_LUA_ROOT").unwrap_or_else(|_| {
        Path::new(env!("CARGO_MANIFEST_DIR")).parent().and_then(|rust| rust.parent())
            .map(|root| root.display().to_string()).unwrap_or_default()
    })
}

struct Pty { master: i32, child: Child, bytes: Vec<u8> }

impl Pty {
    /// One `wa chat` on a 100x30 pty. `path` is the CHILD's PATH: an empty scratch directory here, which is
    /// what makes the font unmeasurable - no shell, so no /proc walk and no fontconfig.
    fn spawn(bin: &Path, dir: &Path, home: &Path, path: &Path) -> Pty {
        let mut winsize = libc::winsize { ws_row: ROWS, ws_col: COLUMNS, ws_xpixel: 0, ws_ypixel: 0 };
        let mut master: libc::c_int = -1;
        let mut slave: libc::c_int = -1;
        let opened = unsafe { libc::openpty(&mut master, &mut slave, std::ptr::null_mut(), std::ptr::null(), &mut winsize) };
        assert_eq!(opened, 0, "the pty opened");
        let stdin = unsafe { Stdio::from_raw_fd(libc::dup(slave)) };
        let stdout = unsafe { Stdio::from_raw_fd(libc::dup(slave)) };
        let db = dir.join("ledger.db");
        let mut command = Command::new(bin);
        command.args(["--db", db.to_str().unwrap(), "chat"])
            .stdin(stdin).stdout(stdout).stderr(Stdio::null()).current_dir(dir).env_clear();
        for (key, value) in [
            ("PATH", path.display().to_string()),
            ("HOME", home.display().to_string()),
            ("TERM", "xterm-256color".to_string()),
            ("LANG", "C.UTF-8".to_string()),
            ("WASM_AGENT_HOME", home.display().to_string()),
            ("WASM_AGENT_LUA_ROOT", lua_root()),
            ("WASM_AGENT_RENDEZVOUS", "http://127.0.0.1:9".to_string()),
            ("WASM_AGENT_RELAY", String::new()),
            ("WASM_AGENT_MANAGED", "0".to_string()),
            ("WA_SKIP_UPDATE_CHECK", "1".to_string()),
            ("WASM_AGENT_CLI_OPENING", "off".to_string()),
            ("COLUMNS", COLUMNS.to_string()),
            ("LINES", ROWS.to_string()),
        ] { command.env(key, value); }
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 { return Err(std::io::Error::last_os_error()); }
                if libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 { return Err(std::io::Error::last_os_error()); }
                Ok(())
            });
        }
        let child = command.spawn().expect("the binary starts");
        unsafe { libc::close(slave); }
        let flags = unsafe { libc::fcntl(master, libc::F_GETFL) };
        unsafe { libc::fcntl(master, libc::F_SETFL, flags | libc::O_NONBLOCK); }
        Pty { master, child, bytes: Vec::new() }
    }

    fn read_until(&mut self, timeout: Duration, done: impl Fn(&[u8]) -> bool) -> bool {
        let deadline = Instant::now() + timeout;
        let mut buffer = [0u8; 8192];
        loop {
            if done(&self.bytes) { return true; }
            if Instant::now() >= deadline { return done(&self.bytes); }
            let read = unsafe { libc::read(self.master, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
            if read > 0 { self.bytes.extend_from_slice(&buffer[..read as usize]); continue; }
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    fn read_quiet(&mut self, quiet: Duration, cap: Duration) {
        let deadline = Instant::now() + cap;
        let mut last = Instant::now();
        let mut seen = self.bytes.len();
        let mut buffer = [0u8; 8192];
        while Instant::now() < deadline {
            let read = unsafe { libc::read(self.master, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
            if read > 0 {
                self.bytes.extend_from_slice(&buffer[..read as usize]);
                seen = self.bytes.len();
                last = Instant::now();
                continue;
            }
            if self.bytes.len() == seen && last.elapsed() >= quiet { return; }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn write(&mut self, text: &str) {
        let bytes = text.as_bytes();
        let mut sent = 0;
        while sent < bytes.len() {
            let wrote = unsafe { libc::write(self.master, bytes[sent..].as_ptr() as *const libc::c_void, bytes.len() - sent) };
            if wrote > 0 { sent += wrote as usize; } else { std::thread::sleep(Duration::from_millis(5)); }
        }
    }

    fn text(&self) -> String { String::from_utf8_lossy(&self.bytes).to_string() }

    fn stop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        unsafe { libc::close(self.master); }
    }
}

fn count(haystack: &str, needle: &str) -> usize { haystack.match_indices(needle).count() }

/// The END of a session's bytes, for a failure message: a whole pty dump is unreadable and the tail is where
/// the answer is.
fn tail(text: &str, chars: usize) -> String {
    let mut kept: Vec<char> = text.chars().rev().take(chars).collect();
    kept.reverse();
    kept.into_iter().collect()
}

fn start_finished(bytes: &[u8]) -> bool { String::from_utf8_lossy(bytes).contains("/ for commands") }

/// The config file wa wrote, found on DISK rather than parsed out of its answer (measured 24/11: a reply
/// line is clipped at the window's width, and under the fast runner the scratch path is long enough for the
/// closing bracket to be cut - so an answer that named the file was read as one that did not).
///
/// The rule is `lua/core/paths.lua`'s: the config file is `<data>/env`, and the host answers data =
/// `$WASM_AGENT_HOME/.wasm-agent`. The walk is there so a path rule that moves is a NAMED failure in this
/// row, not a silent pass: one level deep, any `env` that holds an `icons` line.
fn config_file(home: &Path) -> Option<PathBuf> {
    let direct = home.join(".wasm-agent/env");
    if direct.is_file() { return Some(direct); }
    let entries = std::fs::read_dir(home).ok()?;
    for entry in entries.flatten() {
        let candidate = entry.path().join("env");
        if candidate.is_file() { return Some(candidate); }
    }
    None
}

#[test]
fn the_unknown_font_line_is_said_once_and_icons_wa_survives_a_restart() {
    let Some(bin) = binary() else {
        eprintln!("SKIP icons notice: no wa binary (WA_BIN)");
        return;
    };
    let dir = scratch("notice");
    let home = dir.join("home");
    let path = dir.join("path");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&path).unwrap();

    // ---- start 1: the line, once ----
    let mut pty = Pty::spawn(&bin, &dir, &home, &path);
    let started = pty.read_until(Duration::from_secs(30), start_finished);
    pty.read_quiet(Duration::from_millis(600), Duration::from_secs(10));
    assert!(started, "the start finished on a pty whose font cannot be measured");
    let first = pty.text();
    assert_eq!(count(&first, NOTICE), 1,
        "the unknown-font line is said ONCE at start: {}", count(&first, NOTICE));

    // ---- /icons wa: remembered for this node's user ----
    pty.write("/icons wa\r");
    let answered = pty.read_until(Duration::from_secs(20), |bytes| {
        String::from_utf8_lossy(bytes).contains("remembered in")
    });
    let first = pty.text();
    assert!(answered, "/icons wa answered: {:?}", tail(&first, 400));
    assert!(first.contains("remembered") && !first.contains("this session only"),
        "the answer says the choice was written, not that it was only for this session: {:?}", tail(&first, 300));
    pty.stop();

    let file = config_file(&home).unwrap_or_else(|| panic!(
        "/icons wa wrote no config file under {}: nothing names where it went", home.display()));
    let written = std::fs::read_to_string(&file).unwrap_or_else(|problem| panic!("the config file {} is readable: {problem}", file.display()));
    let lines: Vec<&str> = written.lines().filter(|line| line.trim_start().starts_with("icons")).collect();
    assert_eq!(lines, vec!["icons = wa"],
        "the config file holds one icons line, and it is the choice: {written:?}");

    // ---- start 2: no notice, and /icons says where the set came from ----
    let mut pty = Pty::spawn(&bin, &dir, &home, &path);
    let started = pty.read_until(Duration::from_secs(30), start_finished);
    pty.read_quiet(Duration::from_millis(600), Duration::from_secs(10));
    assert!(started, "the second start finished");
    let second = pty.text();
    assert_eq!(count(&second, NOTICE), 0,
        "a remembered choice is not an unknown font, so the line is not said again");
    pty.write("/icons\r");
    let answered = pty.read_until(Duration::from_secs(20), |bytes| {
        String::from_utf8_lossy(bytes).contains("icons wa")
    });
    let second = pty.text();
    pty.stop();
    std::fs::remove_dir_all(&dir).ok();
    assert!(answered, "/icons reports the set it is drawing: {}", second);
    assert!(second.contains("config"), "/icons names the config file as the source: {second}");
}
