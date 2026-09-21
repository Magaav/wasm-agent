//! Client-tools executor: polls the host bridge and performs desktop actions.
//!
//! Actions: `screenshot`, `frame`, `move`, `click`, `type`, `key`, `shell`,
//! `status`, `browser` and the low-level `cdp` (see `cdp.rs` for everything
//! about the browser).
//!
//! Three properties this loop must keep, each learned the hard way:
//!
//! - **It never dies.** A panic in one action used to kill the only poller,
//!   which made every later call fail as "no client connected" while the window
//!   was perfectly alive. A panic is now caught, logged and answered.
//! - **It never polls blind.** Every poll carries a small state body, so the
//!   node (and therefore the agent) can see what this client is and what it last
//!   did *without* spending a round trip to ask.
//! - **It never outlives the caller.** The caller's budget travels with the
//!   command, and the actions that can block honour it, so a timeout on the
//!   other side means the work really has stopped.
use serde_json::{json, Value};
use std::io::Read;

use std::time::Duration;

use crate::cdp;

pub(crate) fn log(message: &str) {
    use std::io::Write;
    let path = cdp::state_dir().join("wa-window.log");
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(file, "[client] {message}");
    }
}

fn client_port() -> u16 {
    std::env::var("WASM_AGENT_CLIENT_PORT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(8800)
}

pub fn spawn() {
    std::thread::spawn(move || {
        let port = client_port();
        log(&format!("executor polling 127.0.0.1:{port}"));
        let mut failures = 0u32;
        loop {
            let body = json!({ "v": 2, "state": poll_state() }).to_string();
            // The bridge holds this open while it waits for a command, so the
            // read timeout has to be longer than the bridge's own wait.
            let Some(response) = cdp::http("127.0.0.1", port, "POST", "/client/poll", Some(&body), 25_000) else {
                failures += 1;
                cdp::note_poll(false);
                if failures % 10 == 1 {
                    log(&format!("poll unreachable ({failures})"));
                }
                std::thread::sleep(Duration::from_secs(1));
                continue;
            };
            failures = 0;
            cdp::note_poll(true);
            let command: Value = match serde_json::from_str(&response) {
                Ok(value) => value,
                Err(_) => {
                    std::thread::sleep(Duration::from_millis(300));
                    continue;
                }
            };
            let id = command["id"].as_str().unwrap_or_default().to_string();
            if id.is_empty() {
                continue;
            }
            let action = command["action"].as_str().unwrap_or_default().to_string();
            let args = command["args"].clone();
            let budget_ms = command["budget_ms"].as_u64().unwrap_or(75_000);
            log(&format!("run {action} budget={budget_ms}ms"));
            let started = std::time::Instant::now();
            // A panic in one action must not cost the client its poller.
            let result = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                execute(&action, &args, budget_ms)
            })) {
                Ok(value) => value,
                Err(_) => json!({
                    "error": "action_panicked",
                    "observed": format!("the client panicked while running '{action}'"),
                    "next": "the client is still connected: try a different action, or read wa-window.log"
                }),
            };
            let ms = started.elapsed().as_millis() as u64;
            cdp::note_action(&action, result.get("error").is_none(), ms, result["error"].as_str());
            log(&format!("done {action} in {ms}ms"));
            let payload = json!({ "id": id, "result": result }).to_string();
            let delivered = cdp::http("127.0.0.1", port, "POST", "/client/result", Some(&payload), 10_000).is_some();
            if !delivered {
                log(&format!("result for {action} could not be delivered"));
            }
        }
    });
}

/// What the node gets to see without asking: no probes, no network, just what
/// this client knows about itself.
fn poll_state() -> Value {
    let status = cdp::status();
    json!({
        "v": 2,
        "client": status["client"],
        "chrome": status["chrome"],
    })
}

fn execute(action: &str, args: &Value, budget_ms: u64) -> Value {
    match action {
        "screenshot" => screenshot(),
        "move" => {
            let (x, y) = point(args);
            unsafe {
                let _ = SetCursorPos(x, y);
            }
            json!({ "ok": true, "x": x, "y": y })
        }
        "click" => {
            let (x, y) = point(args);
            click(x, y, args["button"].as_str().unwrap_or("left"))
        }
        "type" => {
            let text = args["text"].as_str().unwrap_or_default();
            type_text(text);
            json!({ "ok": true, "chars": text.chars().count() })
        }
        "key" => json!({ "ok": true, "pressed": press_key(args["key"].as_str().unwrap_or_default()) }),
        "shell" => shell(args, budget_ms),
        "frame" => frame(args),
        "status" => cdp::status(),
        "cdp" | "browser" => cdp::run(action, args, budget_ms),
        other => json!({
            "error": format!("unknown_action:{other}"),
            "observed": "this client does not implement that action",
            "next": "use one of screenshot, frame, click, move, type, key, shell, status, browser, cdp"
        }),
    }
}

fn point(args: &Value) -> (i32, i32) {
    (args["x"].as_i64().unwrap_or(0) as i32, args["y"].as_i64().unwrap_or(0) as i32)
}

// ---- shell ---------------------------------------------------------------

/// A command that never returns used to wedge the executor for good, so every
/// shell call is bounded and a killed command says so.
fn shell(args: &Value, budget_ms: u64) -> Value {
    let command = args["command"].as_str().unwrap_or_default();
    if command.is_empty() {
        return json!({ "error": "command_required" });
    }
    let kind = args["shell"].as_str().unwrap_or("cmd");
    let limit_ms = args["timeout_ms"]
        .as_u64()
        .unwrap_or(budget_ms.saturating_sub(2_000))
        .clamp(1_000, 290_000);
    let mut process = if kind.eq_ignore_ascii_case("powershell") {
        let mut powershell = std::process::Command::new("powershell");
        powershell.arg("-NoProfile").arg("-NonInteractive").arg("-Command").arg(command);
        powershell
    } else {
        let mut cmd = std::process::Command::new("cmd");
        cmd.arg("/C").arg(command);
        cmd
    };
    if let Some(dir) = args["cwd"].as_str() {
        if !dir.is_empty() {
            process.current_dir(dir);
        }
    }
    process.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    let mut child = match process.spawn() {
        Ok(child) => child,
        Err(error) => return json!({ "error": error.to_string() }),
    };
    let deadline = std::time::Instant::now() + Duration::from_millis(limit_ms);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if std::time::Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return json!({
                        "error": "shell_timeout",
                        "observed": format!("the command did not finish within {limit_ms}ms and was killed"),
                        "next": "narrow the command, or raise timeout_ms (the node waits for its budget)",
                        "command": command
                    });
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(error) => return json!({ "error": error.to_string() }),
        }
    }
    let mut stdout = String::new();
    let mut stderr = String::new();
    if let Some(mut pipe) = child.stdout.take() {
        let _ = pipe.read_to_string(&mut stdout);
    }
    if let Some(mut pipe) = child.stderr.take() {
        let _ = pipe.read_to_string(&mut stderr);
    }
    if stdout.len() > 20_000 {
        stdout.truncate(20_000);
        stdout.push_str("\n…(truncated)");
    }
    if stderr.len() > 8_000 {
        stderr.truncate(8_000);
        stderr.push_str("\n…(truncated)");
    }
    json!({
        "ok": true,
        "code": child.wait().ok().and_then(|status| status.code()).unwrap_or(-1),
        "stdout": stdout,
        "stderr": stderr
    })
}

// ---- mouse + keyboard ----------------------------------------------------
use windows::Win32::UI::Input::KeyboardAndMouse::{
    keybd_event, mouse_event, VkKeyScanW, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, MOUSEEVENTF_LEFTDOWN,
    MOUSEEVENTF_LEFTUP, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP,
};
use windows::Win32::UI::WindowsAndMessaging::SetCursorPos;

fn click(x: i32, y: i32, button: &str) -> Value {
    unsafe {
        let _ = SetCursorPos(x, y);
        let (down, up) = if button == "right" {
            (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP)
        } else {
            (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP)
        };
        mouse_event(down, 0, 0, 0, 0);
        std::thread::sleep(Duration::from_millis(30));
        mouse_event(up, 0, 0, 0, 0);
    }
    json!({ "ok": true, "x": x, "y": y, "button": button })
}

fn tap(vk: u8, shift: bool) {
    unsafe {
        const SHIFT: u8 = 0x10;
        if shift {
            keybd_event(SHIFT, 0, KEYBD_EVENT_FLAGS(0), 0);
        }
        keybd_event(vk, 0, KEYBD_EVENT_FLAGS(0), 0);
        keybd_event(vk, 0, KEYEVENTF_KEYUP, 0);
        if shift {
            keybd_event(SHIFT, 0, KEYEVENTF_KEYUP, 0);
        }
    }
}

fn type_text(text: &str) {
    for ch in text.chars() {
        let scan = unsafe { VkKeyScanW(ch as u16) };
        if scan == -1 {
            continue;
        }
        let vk = (scan & 0xff) as u8;
        let shift = (scan >> 8) & 0x1 != 0;
        tap(vk, shift);
        std::thread::sleep(Duration::from_millis(8));
    }
}

fn press_key(name: &str) -> bool {
    let vk = match name.to_ascii_lowercase().as_str() {
        "enter" | "return" => 0x0D,
        "tab" => 0x09,
        "esc" | "escape" => 0x1B,
        "space" => 0x20,
        "backspace" => 0x08,
        "delete" => 0x2E,
        "up" => 0x26,
        "down" => 0x28,
        "left" => 0x25,
        "right" => 0x27,
        "home" => 0x24,
        "end" => 0x23,
        "pageup" => 0x21,
        "pagedown" => 0x22,
        other => {
            let mut chars = other.chars();
            match (chars.next(), chars.next()) {
                (Some(ch), None) => {
                    let scan = unsafe { VkKeyScanW(ch as u16) };
                    if scan == -1 {
                        return false;
                    }
                    tap((scan & 0xff) as u8, (scan >> 8) & 0x1 != 0);
                    return true;
                }
                _ => return false,
            }
        }
    };
    tap(vk, false);
    true
}

// ---- screenshot / live frame --------------------------------------------
/// Capture the whole virtual desktop into top-down BGRA pixels.
///
/// This used to capture `SM_CXSCREEN`/`SM_CYSCREEN` from `GetDC(None)` at origin (0,0) -
/// that is the *primary monitor only*. On a machine with two monitors the control view
/// therefore showed one screen and the other simply did not exist. The virtual screen
/// metrics are the union of every monitor: `SM_XVIRTUALSCREEN`/`SM_YVIRTUALSCREEN` are the
/// top-left corner (negative when a monitor sits left of or above the primary one) and the
/// `SM_C*VIRTUALSCREEN` pair is the size. `BitBlt` takes that corner as the source origin.
///
/// The origin is returned with the pixels because it is not recoverable from them: a click
/// at canvas (10, 10) is virtual-screen (origin.x + 10, origin.y + 10), and on a two-monitor
/// desk with the secondary on the left that origin is negative. Callers must add it.
fn capture_screen() -> Option<(i32, i32, Vec<u8>, i32, i32)> {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::Graphics::Gdi::{
        BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits,
        ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, SRCCOPY,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
    };

    unsafe {
        let origin_x = GetSystemMetrics(SM_XVIRTUALSCREEN);
        let origin_y = GetSystemMetrics(SM_YVIRTUALSCREEN);
        let width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        let height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        // A driver that does not answer the virtual metrics (or a session with no desktop)
        // gives 0 here; falling back to the primary monitor is better than a capture_failed
        // that says nothing about why, and it keeps the single-monitor case exactly as it was.
        let (origin_x, origin_y, width, height) = if width <= 0 || height <= 0 {
            (
                0,
                0,
                GetSystemMetrics(windows::Win32::UI::WindowsAndMessaging::SM_CXSCREEN),
                GetSystemMetrics(windows::Win32::UI::WindowsAndMessaging::SM_CYSCREEN),
            )
        } else {
            (origin_x, origin_y, width, height)
        };
        if width <= 0 || height <= 0 {
            return None;
        }
        // The virtual desktop can be enormous (two 4K monitors side by side is 7680x2160).
        // Refuse before allocating rather than failing inside GDI with a half-filled bitmap.
        if width as i64 * height as i64 > 64_000_000 {
            return None;
        }
        let screen = GetDC(None);
        let memory = CreateCompatibleDC(Some(screen));
        let bitmap = CreateCompatibleBitmap(screen, width, height);
        let previous = SelectObject(memory, bitmap.into());
        let _ = BitBlt(memory, 0, 0, width, height, Some(screen), origin_x, origin_y, SRCCOPY);

        let mut info = BITMAPINFO::default();
        info.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
        info.bmiHeader.biWidth = width;
        info.bmiHeader.biHeight = -height; // top-down
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = BI_RGB.0;
        let mut pixels = vec![0u8; (width * height * 4) as usize];
        let lines = GetDIBits(
            memory,
            bitmap,
            0,
            height as u32,
            Some(pixels.as_mut_ptr() as *mut _),
            &mut info,
            DIB_RGB_COLORS,
        );

        SelectObject(memory, previous);
        let _ = DeleteObject(bitmap.into());
        let _ = DeleteDC(memory);
        ReleaseDC(Some(HWND(std::ptr::null_mut())), screen);

        if lines == 0 {
            return None;
        }
        Some((width, height, pixels, origin_x, origin_y))
    }
}

/// How many monitors are attached. Used to tell the reader that the frame covers all of
/// them, which is otherwise unknowable from a picture of a wide desktop.
fn monitor_count() -> i32 {
    use windows::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_CMONITORS};
    unsafe { GetSystemMetrics(SM_CMONITORS) }
}

fn screenshot() -> Value {
    let Some((width, height, pixels, origin_x, origin_y)) = capture_screen() else {
        return json!({ "error": "capture_failed" });
    };
    let path = std::env::temp_dir().join(format!("wa-screenshot-{}.bmp", std::process::id()));
    if let Err(error) = std::fs::write(&path, bmp_bytes(width, height, &pixels)) {
        return json!({ "error": error.to_string() });
    }
    // The origin travels with the screenshot for the same reason it does with a frame:
    // a coordinate the caller reads off the image is only usable with it.
    json!({
        "ok": true, "path": path.to_string_lossy(), "width": width, "height": height,
        "origin_x": origin_x, "origin_y": origin_y, "monitors": monitor_count()
    })
}

struct CachedFrame {
    width: i32,
    height: i32,
    pixels: Vec<u8>,
}

/// Last frame we sent, so we can send only what changed.
static FRAME_CACHE: std::sync::Mutex<Option<CachedFrame>> = std::sync::Mutex::new(None);

const TILE: i32 = 64;

/// A live frame for the control view. Returns tiles: the first call is a full
/// frame, later calls carry only the 64x64 tiles that changed, which is what
/// makes it usable in real time instead of shipping whole screenshots.
fn frame(args: &Value) -> Value {
    let Some((width, height, pixels, origin_x, origin_y)) = capture_screen() else {
        return json!({ "error": "capture_failed" });
    };
    let max_width = args["max_width"].as_i64().unwrap_or(800).clamp(160, 1920) as i32;
    let scale = (max_width as f64 / width as f64).min(1.0);
    let out_w = ((width as f64 * scale).round() as i32).max(1);
    let out_h = ((height as f64 * scale).round() as i32).max(1);

    let mut out = vec![0u8; (out_w * out_h * 4) as usize];
    for y in 0..out_h {
        let sy = ((y as f64 / scale) as i32).min(height - 1);
        for x in 0..out_w {
            let sx = ((x as f64 / scale) as i32).min(width - 1);
            let src = ((sy * width + sx) * 4) as usize;
            let dst = ((y * out_w + x) * 4) as usize;
            out[dst..dst + 4].copy_from_slice(&pixels[src..src + 4]);
        }
    }

    let mut tiles: Vec<Value> = Vec::new();
    let mut guard = match FRAME_CACHE.lock() {
        Ok(guard) => guard,
        Err(_) => return json!({ "error": "frame_lock" }),
    };
    let previous = guard.take();
    let same_size = previous
        .as_ref()
        .map(|cached| cached.width == out_w && cached.height == out_h)
        .unwrap_or(false);
    let full = args["full"].as_bool().unwrap_or(false) || !same_size;

    if full {
        tiles.push(tile_json(0, 0, out_w, out_h, out_w, &out));
    } else if let Some(cached) = previous.as_ref() {
        let mut y = 0;
        while y < out_h {
            let mut x = 0;
            while x < out_w {
                let w = TILE.min(out_w - x);
                let h = TILE.min(out_h - y);
                if region_differs(&out, out_w, &cached.pixels, x, y, w, h) {
                    tiles.push(tile_json(x, y, w, h, out_w, &out));
                }
                x += TILE;
            }
            y += TILE;
        }
    }
    *guard = Some(CachedFrame { width: out_w, height: out_h, pixels: out });

    json!({
        "ok": true,
        "width": out_w,
        "height": out_h,
        "screen_width": width,
        "screen_height": height,
        // The virtual desktop's top-left in screen coordinates. A click at canvas (x, y)
        // is screen (origin_x + x, origin_y + y) - without this the control view clicks in
        // the wrong place as soon as the desktop has a monitor above or left of the primary.
        "origin_x": origin_x,
        "origin_y": origin_y,
        // The count, so the reader can be told the frame is all of them and not just one.
        "monitors": monitor_count(),
        "scale": scale,
        "full": full,
        "tiles": tiles
    })
}

fn region_differs(frame: &[u8], stride_px: i32, other: &[u8], x: i32, y: i32, w: i32, h: i32) -> bool {
    for row in 0..h {
        let start = (((y + row) * stride_px + x) * 4) as usize;
        let end = start + (w * 4) as usize;
        if frame.get(start..end) != other.get(start..end) {
            return true;
        }
    }
    false
}

fn tile_json(x: i32, y: i32, w: i32, h: i32, stride_px: i32, frame: &[u8]) -> Value {
    let mut pixels = Vec::with_capacity((w * h * 4) as usize);
    for row in 0..h {
        let start = (((y + row) * stride_px + x) * 4) as usize;
        pixels.extend_from_slice(&frame[start..start + (w * 4) as usize]);
    }
    json!({
        "x": x,
        "y": y,
        "w": w,
        "h": h,
        "image": cdp::base64(&bmp_bytes(w, h, &pixels))
    })
}

fn bmp_bytes(width: i32, height: i32, pixels: &[u8]) -> Vec<u8> {
    let size = pixels.len() as u32;
    let mut out = Vec::with_capacity(54 + pixels.len());
    out.extend_from_slice(b"BM");
    out.extend_from_slice(&(54 + size).to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&54u32.to_le_bytes());
    out.extend_from_slice(&40u32.to_le_bytes());
    out.extend_from_slice(&width.to_le_bytes());
    out.extend_from_slice(&height.to_le_bytes()); // positive = bottom-up
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&32u16.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&size.to_le_bytes());
    out.extend_from_slice(&2835u32.to_le_bytes());
    out.extend_from_slice(&2835u32.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    // Pixels are top-down; BMP rows are bottom-up, so write them in reverse.
    let stride = (width * 4) as usize;
    for row in (0..height as usize).rev() {
        out.extend_from_slice(&pixels[row * stride..(row + 1) * stride]);
    }
    out
}
