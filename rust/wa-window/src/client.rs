//! Client-tools executor: polls the host bridge and performs desktop actions.
//!
//! Actions: `screenshot`, `move`, `click`, `type`, `key`, `cdp`. HTTP is plain
//! localhost, so this uses a tiny hand-rolled client rather than a dependency.
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

pub fn spawn() {
    std::thread::spawn(move || {
        let port: u16 = std::env::var("WASM_AGENT_CLIENT_PORT")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(8800);
        loop {
            let Some(body) = http(port, "GET", "/client/poll", None) else {
                std::thread::sleep(Duration::from_secs(1));
                continue;
            };
            let command: Value = match serde_json::from_str(&body) {
                Ok(value) => value,
                Err(_) => {
                    std::thread::sleep(Duration::from_millis(300));
                    continue;
                }
            };
            let id = command["id"].as_str().unwrap_or_default().to_string();
            if id.is_empty() {
                std::thread::sleep(Duration::from_millis(200));
                continue;
            }
            let result = execute(command["action"].as_str().unwrap_or_default(), &command["args"]);
            let payload = json!({"id": id, "result": result}).to_string();
            let _ = http(port, "POST", "/client/result", Some(&payload));
        }
    });
}

fn http(port: u16, method: &str, path: &str, body: Option<&str>) -> Option<String> {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(30))).ok()?;
    let payload = body.unwrap_or("");
    let request = format!(
        "{method} {path} HTTP/1.0\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n{payload}",
        payload.len()
    );
    stream.write_all(request.as_bytes()).ok()?;
    let mut response = String::new();
    stream.read_to_string(&mut response).ok()?;
    response.split_once("\r\n\r\n").map(|(_, body)| body.to_string())
}

fn execute(action: &str, args: &Value) -> Value {
    match action {
        "screenshot" => screenshot(),
        "move" => {
            let (x, y) = point(args);
            unsafe { let _ = SetCursorPos(x, y); }
            json!({"ok": true, "x": x, "y": y})
        }
        "click" => {
            let (x, y) = point(args);
            click(x, y, args["button"].as_str().unwrap_or("left"))
        }
        "type" => {
            let text = args["text"].as_str().unwrap_or_default();
            type_text(text);
            json!({"ok": true, "chars": text.chars().count()})
        }
        "key" => json!({"ok": press_key(args["key"].as_str().unwrap_or_default())}),
        "cdp" => cdp(args),
        other => json!({"error": format!("unknown_action:{other}")}),
    }
}

fn point(args: &Value) -> (i32, i32) {
    (args["x"].as_i64().unwrap_or(0) as i32, args["y"].as_i64().unwrap_or(0) as i32)
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
    json!({"ok": true, "x": x, "y": y, "button": button})
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
                    if scan == -1 { return false; }
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

// ---- screenshot ----------------------------------------------------------
fn screenshot() -> Value {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::Graphics::Gdi::{
        BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits,
        ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, SRCCOPY,
    };
    use windows::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_CXSCREEN, SM_CYSCREEN};

    unsafe {
        let width = GetSystemMetrics(SM_CXSCREEN);
        let height = GetSystemMetrics(SM_CYSCREEN);
        if width <= 0 || height <= 0 {
            return json!({"error": "no_display"});
        }
        let screen = GetDC(None);
        let memory = CreateCompatibleDC(Some(screen));
        let bitmap = CreateCompatibleBitmap(screen, width, height);
        let previous = SelectObject(memory, bitmap.into());
        let _ = BitBlt(memory, 0, 0, width, height, Some(screen), 0, 0, SRCCOPY);

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
            return json!({"error": "capture_failed"});
        }

        let path = std::env::temp_dir().join(format!("wa-screenshot-{}.bmp", std::process::id()));
        if let Err(error) = write_bmp(&path, width, height, &pixels) {
            return json!({"error": error});
        }
        json!({"ok": true, "path": path.to_string_lossy(), "width": width, "height": height})
    }
}

fn write_bmp(path: &std::path::Path, width: i32, height: i32, pixels: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let size = (pixels.len()) as u32;
    let mut file = std::fs::File::create(path).map_err(|error| error.to_string())?;
    let mut header = Vec::with_capacity(54);
    header.extend_from_slice(b"BM");
    header.extend_from_slice(&(54 + size).to_le_bytes()); // file size
    header.extend_from_slice(&0u16.to_le_bytes()); // reserved
    header.extend_from_slice(&0u16.to_le_bytes()); // reserved
    header.extend_from_slice(&54u32.to_le_bytes()); // pixel offset
    header.extend_from_slice(&40u32.to_le_bytes()); // header size
    header.extend_from_slice(&width.to_le_bytes());
    header.extend_from_slice(&height.to_le_bytes()); // positive = bottom-up; pixels are top-down, flip
    header.extend_from_slice(&1u16.to_le_bytes()); // planes
    header.extend_from_slice(&32u16.to_le_bytes()); // bpp
    header.extend_from_slice(&0u32.to_le_bytes()); // compression
    header.extend_from_slice(&size.to_le_bytes());
    header.extend_from_slice(&2835u32.to_le_bytes());
    header.extend_from_slice(&2835u32.to_le_bytes());
    header.extend_from_slice(&0u32.to_le_bytes());
    header.extend_from_slice(&0u32.to_le_bytes());
    file.write_all(&header).map_err(|error| error.to_string())?;
    // GDI gives bottom-up rows; our buffer is top-down, so write rows in reverse.
    let stride = (width * 4) as usize;
    for row in (0..height as usize).rev() {
        file.write_all(&pixels[row * stride..(row + 1) * stride]).map_err(|error| error.to_string())?;
    }
    Ok(())
}

// ---- CDP (Chrome DevTools Protocol, HTTP endpoints) ----------------------
fn cdp(args: &Value) -> Value {
    let port = args["port"].as_i64().unwrap_or(9222) as u16;
    let target = args["target"].as_str().unwrap_or("list");
    let url = args["url"].as_str().unwrap_or("about:blank");
    let id = args["id"].as_str().unwrap_or_default();
    let (method, path) = match target {
        "open" => ("PUT", format!("/json/new?{}", url)),
        "close" => ("GET", format!("/json/close/{id}")),
        "activate" => ("GET", format!("/json/activate/{id}")),
        _ => ("GET", "/json/list".to_string()),
    };
    match http(port, method, &path, None) {
        Some(body) => json!({"ok": true, "target": target, "result": body}),
        None => json!({"error": "cdp_unreachable", "hint": format!("no DevTools endpoint on 127.0.0.1:{port}")}),
    }
}
