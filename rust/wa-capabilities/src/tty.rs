//! The node's own tty: the funnel every screen byte goes through, the hold the launch animation keeps
//! it in, and raw mode.
//!
//! MOVED OUT OF `wa-term` in the last slice of `wa-term-own-program`. It is I/O, not display: the
//! drawing lives in the terminal program (`rust/wa-term/src/bin/wa-term.rs`) and answers frames, and
//! this module is what puts a frame on the operator's screen. Keeping it here is what lets the node
//! stop linking the drawing crate without carrying a second tty writer.
//!
//! The bytes are unchanged from the code it replaced (`wa_term::terminal_editor::{write, write_now,
//! hold, release, try_raw}`), and so is the order they go out in: the hold is one flag on the one
//! funnel, and the raw mode restores the terminal AND the stderr it diverted when it drops.
use std::io::{self, Write};
use std::sync::Mutex;

static OUTPUT: Mutex<()> = Mutex::new(());

/// While the opening owns the screen, every write is KEPT instead of drawn: the animation is on the
/// alternate screen, and a frame of the chat written into it would land on top of the rain. `hold`
/// starts keeping them and `release` hands back exactly what was kept, in order.
///
/// The hold lives here because this function is the one funnel every console write goes through - the
/// view's `terminal_write`, the transcript's frames, the ticker and the editor's own rows - so one
/// flag covers them all.
static HELD: Mutex<Option<String>> = Mutex::new(None);

pub fn hold() { *HELD.lock().unwrap_or_else(|e| e.into_inner()) = Some(String::new()); }

/// Stop keeping writes, answering what was kept (empty when nothing was).
pub fn release() -> String {
    HELD.lock().unwrap_or_else(|e| e.into_inner()).take().unwrap_or_default()
}

pub fn write(text: &str) -> io::Result<()> {
    {
        let mut held = HELD.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(buffer) = held.as_mut() {
            buffer.push_str(text);
            return Ok(());
        }
    }
    write_now(text)
}

/// The same funnel with the hold ignored: the opening's own frames, and the writes that give the
/// screen back at the very end of it.
pub fn write_now(text: &str) -> io::Result<()> {
    let _guard = OUTPUT.lock().unwrap_or_else(|e| e.into_inner());
    let mut out = io::stdout().lock();
    out.write_all(text.as_bytes())?;
    out.flush()
}

#[cfg(unix)]
pub struct RawMode(libc::termios, Option<libc::c_int>);
#[cfg(unix)]
pub fn try_raw() -> Option<RawMode> {
    // A redirected stdin is a line stream, not a terminal: do not change it.
    let mut old = unsafe { std::mem::zeroed() };
    if unsafe { libc::tcgetattr(0, &mut old) } != 0 { return None; }
    let mut raw = old;
    unsafe { libc::cfmakeraw(&mut raw) };
    if unsafe { libc::tcsetattr(0, libc::TCSANOW, &raw) } != 0 { return None; }
    Some(RawMode(old, divert_stderr()))
}
#[cfg(unix)]
impl Drop for RawMode {
    fn drop(&mut self) {
        unsafe { libc::tcsetattr(0, libc::TCSANOW, &self.0); }
        if let Some(saved) = self.1.take() { unsafe { libc::dup2(saved, 2); libc::close(saved); } }
    }
}

/// While the editor owns the screen, nothing else may write to it: a background thread's
/// `eprintln!` (the graph indexer's progress, a `[lua]` log line) would land in the middle of the
/// chat or the input box, at whatever row the cursor was on. A terminal stderr is pointed at
/// `~/.wasm-agent/logs/cli-stderr.log` until the editor stops; a stderr already redirected by the
/// caller is theirs and is left alone. Returns the saved descriptor that Drop puts back.
#[cfg(unix)]
fn divert_stderr() -> Option<libc::c_int> {
    use std::os::unix::io::IntoRawFd;
    if unsafe { libc::isatty(2) } != 1 { return None; }
    let dir = std::path::PathBuf::from(wa_host_support::paths::resolve_home()).join(".wasm-agent").join("logs");
    std::fs::create_dir_all(&dir).ok()?;
    let log = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("cli-stderr.log")).ok()?;
    let saved = unsafe { libc::dup(2) };
    if saved < 0 { return None; }
    let fd = log.into_raw_fd();
    let moved = unsafe { libc::dup2(fd, 2) };
    unsafe { libc::close(fd); }
    if moved < 0 { unsafe { libc::close(saved); } return None; }
    Some(saved)
}

#[cfg(windows)]
pub struct RawMode {
    handle: *mut std::ffi::c_void, mode: u32, codepage: u32,
    output: *mut std::ffi::c_void, output_mode: u32,
}
#[cfg(windows)]
unsafe impl Send for RawMode {} // the handle belongs to this process for its entire life
#[cfg(windows)]
pub fn try_raw() -> Option<RawMode> {
    use std::ffi::c_void;
    extern "system" {
        fn GetStdHandle(kind: u32) -> *mut c_void;
        fn GetConsoleMode(handle: *mut c_void, mode: *mut u32) -> i32;
        fn SetConsoleMode(handle: *mut c_void, mode: u32) -> i32;
        fn GetConsoleCP() -> u32;
        fn SetConsoleCP(codepage: u32) -> i32;
    }
    unsafe {
        let handle = GetStdHandle(0xffff_fff6); // STD_INPUT_HANDLE
        let mut mode = 0;
        if handle.is_null() || GetConsoleMode(handle, &mut mode) == 0 { return None; }
        // Disable line/echo/processed input. VT input gives escape sequences for arrows
        // through the same byte stream as UTF-8 text; keep the other console flags.
        let raw = (mode & !(0x0001 | 0x0002 | 0x0004)) | 0x0200;
        if SetConsoleMode(handle, raw) == 0 { return None; }
        let output = GetStdHandle(0xffff_fff5);
        let mut output_mode = 0;
        if GetConsoleMode(output, &mut output_mode) == 0 || SetConsoleMode(output, output_mode | 0x0005) == 0 {
            SetConsoleMode(handle, mode);
            return None;
        }
        let codepage = GetConsoleCP();
        if SetConsoleCP(65001) == 0 {
            SetConsoleMode(handle, mode);
            SetConsoleMode(output, output_mode);
            return None;
        }
        Some(RawMode { handle, mode, codepage, output, output_mode })
    }
}
#[cfg(windows)]
impl Drop for RawMode {
    fn drop(&mut self) {
        use std::ffi::c_void;
        extern "system" {
            fn SetConsoleMode(handle: *mut c_void, mode: u32) -> i32;
            fn SetConsoleCP(codepage: u32) -> i32;
        }
        unsafe {
            SetConsoleMode(self.handle, self.mode);
            SetConsoleMode(self.output, self.output_mode);
            SetConsoleCP(self.codepage);
        }
    }
}
#[cfg(not(any(unix, windows)))]
pub struct RawMode;
#[cfg(not(any(unix, windows)))]
pub fn try_raw() -> Option<RawMode> { None }
