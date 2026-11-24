//! The collapse's landing cell, measured frame by frame in a real pty (Fable, 24/11: the one-row flick).
//!
//! WHAT THIS PROVES. The opening's last beat draws the welcome block and collapses into the welcome line's
//! `✻`. The chat then draws the same block behind it. This row asserts that the star's CELL is the same in
//! three places - the opening's LAST frame, the chat's FIRST frame, and the settled screen - at 80x24, 120x40
//! and 200x60, and, stronger than those three points, that EVERY frame in between draws it in that same cell.
//! A block drawn in two writes is two frames: the transcript is bottom-anchored, so the first of them would
//! draw the block one row short and the star one row low for a paint (measured 24/11 on the installed binary:
//! opening (11,1), first paint (12,1), settled (11,1) - the one-row flick). The per-frame assertion is what
//! catches that, which a comparison of settled screens cannot.
//!
//! HOW A FRAME IS READ. The child's bytes are kept with the LENGTH of every read: the opening's last frame is
//! everything up to the byte that leaves the alternate screen (`ESC[?1049l`), and every read after it is fed
//! into a second terminal in memory (`wa_term::scroll::vt::Vt`, the render tests' own decoder) and SNAPSHOTTED
//! - one snapshot per read, so a write the pty hands over in pieces is still checked piece by piece.
//!
//! Isolation: its own scratch HOME under the temp root, and a refusal - never a pass - when no scratch root
//! outside the operator's own ~/.wasm-agent exists. The binary comes from `WA_BIN`; without one this row says
//! SKIP and passes: it cannot tell, and it does not pretend.
#![cfg(unix)]

use std::os::unix::io::FromRawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use wa_term::scroll::vt::Vt;

/// The welcome line's star (U+273B), the glyph the collapse lands on.
const STAR: char = '\u{273b}';

fn binary() -> Option<PathBuf> {
    let asked = std::env::var("WA_BIN").or_else(|_| std::env::var("WA_FAST_BIN")).ok()?;
    let path = PathBuf::from(asked);
    if !path.is_file() { return None; }
    Some(path)
}

fn scratch(tag: &str) -> PathBuf {
    let real = PathBuf::from(format!("{}/.wasm-agent", std::env::var("HOME").unwrap_or_default()));
    for base in [std::env::temp_dir(), PathBuf::from("/tmp"), PathBuf::from("/var/tmp")] {
        if base.starts_with(&real) { continue; }
        let dir = base.join(format!("wa-collapse-{}-{}", tag, std::process::id()));
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

struct Pty { master: i32, child: Child }

impl Pty {
    fn spawn(bin: &Path, dir: &Path, home: &Path, columns: u16, rows: u16) -> Pty {
        let mut winsize = libc::winsize { ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0 };
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
            ("PATH", "/usr/bin:/bin".to_string()),
            ("HOME", home.display().to_string()),
            ("TERM", "xterm-256color".to_string()),
            ("LANG", "C.UTF-8".to_string()),
            ("WASM_AGENT_HOME", home.display().to_string()),
            ("WASM_AGENT_LUA_ROOT", lua_root()),
            ("WASM_AGENT_RENDEZVOUS", "http://127.0.0.1:9".to_string()),
            ("WASM_AGENT_RELAY", String::new()),
            ("WASM_AGENT_MANAGED", "0".to_string()),
            ("WA_SKIP_UPDATE_CHECK", "1".to_string()),
            ("COLUMNS", columns.to_string()),
            ("LINES", rows.to_string()),
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
        Pty { master, child }
    }

    /// Read until the start has settled: the prompt's own last header line is on the stream and nothing new
    /// has arrived for 700 ms. Every read's byte LENGTH is kept, which is what makes a frame boundary.
    fn read_until_settled(&mut self) -> (Vec<u8>, Vec<usize>) {
        let mut bytes: Vec<u8> = Vec::new();
        let mut marks: Vec<usize> = Vec::new();
        let mut buffer = [0u8; 8192];
        let deadline = Instant::now() + Duration::from_secs(45);
        let mut quiet = Instant::now();
        while Instant::now() < deadline {
            let read = unsafe { libc::read(self.master, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
            if read > 0 {
                bytes.extend_from_slice(&buffer[..read as usize]);
                marks.push(bytes.len());
                quiet = Instant::now();
                continue;
            }
            if quiet.elapsed() >= Duration::from_millis(700)
                && String::from_utf8_lossy(&bytes).contains("memory: ") { break; }
            std::thread::sleep(Duration::from_millis(5));
        }
        (bytes, marks)
    }

    fn stop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        unsafe { libc::close(self.master); }
    }
}

/// The welcome line's star on a screen: (row, col), 1-based, first row-major. `None` when this frame does not
/// hold it yet - a frame still being written - which is not a failure by itself (the invariant is over the
/// frames that DO hold it).
fn star(vt: &Vt) -> Option<(usize, usize)> {
    for (index, row) in vt.rows().iter().enumerate() {
        for (column, ch) in row.chars().enumerate() {
            if ch == STAR { return Some((index + 1, column + 1)); }
        }
    }
    None
}

fn measure(bin: &Path, columns: u16, rows: u16) {
    let dir = scratch(&format!("{columns}x{rows}"));
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let mut pty = Pty::spawn(bin, &dir, &home, columns, rows);
    let (bytes, marks) = pty.read_until_settled();
    pty.stop();
    std::fs::remove_dir_all(&dir).ok();

    let text = String::from_utf8_lossy(&bytes).to_string();
    let left = text.find("\u{1b}[?1049l")
        .unwrap_or_else(|| panic!("{columns}x{rows}: the opening never gave the screen back - nothing here was measured"));

    // THE OPENING'S LAST FRAME: everything up to the byte that leaves the alternate screen.
    let mut opening = Vt::new(columns as usize, rows as usize);
    opening.feed(&bytes[..left]);
    let landed = star(&opening).unwrap_or_else(|| panic!(
        "{columns}x{rows}: the last opening frame draws no welcome star - nothing was measured: {:?}", opening.rows()));

    // EVERY FRAME AFTER IT, one snapshot per read, checked in order.
    let mut chat = Vt::new(columns as usize, rows as usize);
    let mut fed = 0usize;
    let mut frames: Vec<Option<(usize, usize)>> = Vec::new();
    for len in &marks {
        chat.feed(&bytes[fed..*len]);
        fed = *len;
        if *len > left { frames.push(star(&chat)); }
    }
    let first = frames.iter().flatten().next().copied().unwrap_or_else(|| panic!(
        "{columns}x{rows}: no frame after the opening draws the welcome star: {:?}", chat.rows()));
    let settled = star(&chat).unwrap_or_else(|| panic!("{columns}x{rows}: the settled screen holds no star"));
    let elsewhere: Vec<(usize, (usize, usize))> = frames.iter().enumerate()
        .filter_map(|(index, cell)| cell.filter(|c| *c != landed).map(|c| (index + 1, c))).collect();

    assert_eq!(first, landed,
        "{columns}x{rows}: the chat's FIRST frame draws the star at {first:?}, the opening's last frame at {landed:?} - that is the flick");
    assert!(elsewhere.is_empty(),
        "{columns}x{rows}: the star moves during the hand-over: frame(s) {elsewhere:?} put it somewhere other than {landed:?}");
    assert_eq!(settled, landed, "{columns}x{rows}: the settled screen draws the star at {settled:?}, the opening at {landed:?}");
}

#[test]
fn the_collapse_lands_on_the_cell_the_chat_draws_and_no_frame_moves_it() {
    let Some(bin) = binary() else {
        eprintln!("SKIP collapse: no wa binary (WA_BIN); this row reads a real pty and cannot tell without one");
        return;
    };
    for (columns, rows) in [(80u16, 24u16), (120, 40), (200, 60)] {
        measure(&bin, columns, rows);
    }
}
