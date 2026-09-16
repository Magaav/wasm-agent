//! Client-tools executor: polls the host bridge and performs desktop actions.
//!
//! Actions: `screenshot`, `move`, `click`, `type`, `key`, `cdp`. HTTP is plain
//! localhost, so this uses a tiny hand-rolled client rather than a dependency.
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

fn log(message: &str) {
    use std::io::Write;
    let base = std::env::var("LOCALAPPDATA").unwrap_or_else(|_| ".".into());
    let path = std::path::PathBuf::from(base).join("wasm-agent").join("wa-window.log");
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(file, "[client] {message}");
    }
}

pub fn spawn() {
    std::thread::spawn(move || {
        let port: u16 = std::env::var("WASM_AGENT_CLIENT_PORT")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(8800);
        log(&format!("executor polling 127.0.0.1:{port}"));
        let mut failures = 0u32;
        loop {
            let Some(body) = http(port, "GET", "/client/poll", None) else {
                failures += 1;
                if failures % 10 == 1 {
                    log(&format!("poll unreachable ({failures})"));
                }
                std::thread::sleep(Duration::from_secs(1));
                continue;
            };
            failures = 0;
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
            let action = command["action"].as_str().unwrap_or_default().to_string();
            log(&format!("run {action}"));
            let result = execute(&action, &command["args"]);
            let payload = json!({"id": id, "result": result}).to_string();
            let delivered = http(port, "POST", "/client/result", Some(&payload)).is_some();
            log(&format!("done {action} delivered={delivered}"));
        }
    });
}

fn http(port: u16, method: &str, path: &str, body: Option<&str>) -> Option<String> {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(30))).ok()?;
    let payload = body.unwrap_or("");
    // HTTP/1.1: Chrome's DevTools endpoint refuses HTTP/1.0 requests.
    let request = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nContent-Type: application/json\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n{payload}",
        port,
        payload.len()
    );
    stream.write_all(request.as_bytes()).ok()?;

    // Read headers, then exactly Content-Length bytes: Chrome keeps the socket
    // open, so reading to EOF would block until the timeout.
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        if stream.read(&mut byte).ok()? == 0 {
            break;
        }
        head.push(byte[0]);
        if head.len() > 65536 {
            break;
        }
    }
    let head_text = String::from_utf8_lossy(&head).to_ascii_lowercase();
    let length = head_text.lines().find_map(|line| {
        line.strip_prefix("content-length:")
            .and_then(|value| value.trim().parse::<usize>().ok())
    });

    let mut body = Vec::new();
    match length {
        Some(expected) => {
            body.resize(expected, 0);
            let _ = stream.read_exact(&mut body);
        }
        None => {
            let _ = stream.read_to_end(&mut body);
        }
    }
    Some(String::from_utf8_lossy(&body).to_string())
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

// ---- CDP (Chrome DevTools Protocol) --------------------------------------
// Uses the wasm-agent Chrome account (a dedicated profile) and launches Chrome
// with remote debugging if it is not already running.
const DEFAULT_CDP_PORT: u16 = 9222;

fn default_profile() -> String {
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        return format!("{local}\\AgentBrowserChromeProfile");
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    format!("{home}/.wasm-agent/chrome")
}

fn find_chrome() -> Option<String> {
    let candidates = [
        std::env::var("PROGRAMFILES").ok(),
        std::env::var("ProgramFiles(x86)").ok(),
        std::env::var("LOCALAPPDATA").ok(),
    ];
    for base in candidates.into_iter().flatten() {
        let path = format!("{base}\\Google\\Chrome\\Application\\chrome.exe");
        if std::path::Path::new(&path).exists() {
            return Some(path);
        }
    }
    None
}

fn chrome_alive(port: u16) -> bool {
    http(port, "GET", "/json/version", None)
        .map(|body| body.contains("webSocketDebuggerUrl"))
        .unwrap_or(false)
}

/// Ensure Chrome is up with remote debugging. Creates the profile if missing.
fn ensure_chrome(port: u16, profile: &str) -> Value {
    if chrome_alive(port) {
        return json!({"running": true, "port": port, "profile": profile});
    }
    let Some(chrome) = find_chrome() else {
        return json!({"error": "chrome_not_found"});
    };
    let mut command = std::process::Command::new(&chrome);
    command
        .arg(format!("--remote-debugging-port={port}"))
        .arg(format!("--user-data-dir={profile}"))
        .arg("--no-first-run")
        .arg("--no-default-browser-check")
        .arg("--restore-last-session")
        .arg("about:blank");
    if command.spawn().is_err() {
        return json!({"error": "chrome_launch_failed"});
    }
    // First launch of a large existing profile can take a while.
    for _ in 0..140 {
        std::thread::sleep(Duration::from_millis(250));
        if chrome_alive(port) {
            return json!({"running": true, "launched": true, "port": port, "profile": profile});
        }
    }
    json!({"error": "chrome_start_timeout", "profile": profile})
}

fn cdp(args: &Value) -> Value {
    let port = args["port"].as_i64().unwrap_or(DEFAULT_CDP_PORT as i64) as u16;
    let profile = args["profile"].as_str().map(str::to_string).unwrap_or_else(default_profile);
    let action = args["target"].as_str().unwrap_or("list");
    let url = args["url"].as_str().unwrap_or("about:blank");
    let id = args["id"].as_str().unwrap_or_default();
    let script = args["script"].as_str().or_else(|| args["text"].as_str()).unwrap_or_default();

    let chrome = ensure_chrome(port, &profile);
    if chrome.get("error").is_some() {
        return chrome;
    }

    let result = match action {
        "launch" => Ok(json!({"running": true})),
        "evaluate" => evaluate(port, script).map(|value| json!({"value": value})),
        "navigate" => evaluate(port, &format!("location.href = {}", json!(url)))
            .map(|_| json!({"navigated": url})),
        "open" => http(port, "PUT", &format!("/json/new?{url}"), None)
            .map(|body| json!({"target": body}))
            .ok_or_else(|| "cdp_unreachable".to_string()),
        "close" => http(port, "GET", &format!("/json/close/{id}"), None)
            .map(|body| json!({"closed": body}))
            .ok_or_else(|| "cdp_unreachable".to_string()),
        "activate" => http(port, "GET", &format!("/json/activate/{id}"), None)
            .map(|body| json!({"activated": body}))
            .ok_or_else(|| "cdp_unreachable".to_string()),
        _ => http(port, "GET", "/json/list", None)
            .map(|body| json!({"targets": parse_targets(&body)}))
            .ok_or_else(|| "cdp_unreachable".to_string()),
    };

    match result {
        Ok(value) => {
            let mut object = value;
            if let Some(map) = object.as_object_mut() {
                map.insert("ok".into(), json!(true));
                map.insert("chrome".into(), chrome);
            }
            object
        }
        Err(error) => json!({"error": error, "chrome": chrome}),
    }
}

fn parse_targets(body: &str) -> Value {
    match serde_json::from_str::<Value>(body) {
        Ok(Value::Array(items)) => Value::Array(
            items
                .into_iter()
                .map(|item| json!({
                    "id": item["id"],
                    "type": item["type"],
                    "title": item["title"],
                    "url": item["url"],
                }))
                .collect(),
        ),
        _ => json!([]),
    }
}

/// Run `Runtime.evaluate` in the first page target over a WebSocket.
fn page_ws(list: &str) -> Option<String> {
    let targets: Value = serde_json::from_str(list).ok()?;
    targets
        .as_array()?
        .iter()
        .find(|item| item["type"] == "page" && item["webSocketDebuggerUrl"].is_string())
        .and_then(|item| item["webSocketDebuggerUrl"].as_str())
        .map(str::to_string)
}

fn evaluate(port: u16, script: &str) -> Result<Value, String> {
    let mut list = http(port, "GET", "/json/list", None).ok_or("cdp_unreachable")?;
    let mut ws_url = page_ws(&list);
    if ws_url.is_none() {
        // Nothing to evaluate in yet: open a blank tab and retry once.
        let _ = http(port, "PUT", "/json/new?about:blank", None);
        std::thread::sleep(Duration::from_millis(800));
        list = http(port, "GET", "/json/list", None).ok_or("cdp_unreachable")?;
        ws_url = page_ws(&list);
    }
    let ws_url = ws_url.ok_or("no_page_target")?;
    let message = json!({
        "id": 1,
        "method": "Runtime.evaluate",
        "params": {"expression": script, "returnByValue": true, "awaitPromise": true}
    })
    .to_string();
    let response = ws_call(&ws_url, &message)?;
    let parsed: Value = serde_json::from_str(&response).map_err(|error| error.to_string())?;
    Ok(parsed["result"]["result"].clone())
}

fn ws_call(url: &str, message: &str) -> Result<String, String> {
    let rest = url.strip_prefix("ws://").ok_or("bad_ws_url")?;
    let (authority, path) = match rest.find('/') {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, "/"),
    };
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => (host, port.parse::<u16>().map_err(|error| error.to_string())?),
        None => (authority, 80),
    };
    let mut stream = TcpStream::connect((host, port)).map_err(|error| error.to_string())?;
    stream.set_read_timeout(Some(Duration::from_secs(20))).ok();

    let key = base64(&random_bytes(16));
    let handshake = format!(
        "GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n\
         Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    );
    stream.write_all(handshake.as_bytes()).map_err(|error| error.to_string())?;

    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        if stream.read(&mut byte).map_err(|error| error.to_string())? == 0 {
            return Err("ws_handshake_closed".into());
        }
        head.push(byte[0]);
        if head.len() > 16384 {
            return Err("ws_handshake_overflow".into());
        }
    }
    if !String::from_utf8_lossy(&head).contains(" 101") {
        return Err("ws_upgrade_failed".into());
    }

    let payload = message.as_bytes();
    let mask = random_bytes(4);
    let mut frame = Vec::with_capacity(payload.len() + 14);
    frame.push(0x81); // FIN + text
    match payload.len() {
        len if len < 126 => frame.push(0x80 | len as u8),
        len if len <= 0xffff => {
            frame.push(0x80 | 126);
            frame.extend_from_slice(&(len as u16).to_be_bytes());
        }
        len => {
            frame.push(0x80 | 127);
            frame.extend_from_slice(&(len as u64).to_be_bytes());
        }
    }
    frame.extend_from_slice(&mask);
    for (index, byte) in payload.iter().enumerate() {
        frame.push(byte ^ mask[index % 4]);
    }
    stream.write_all(&frame).map_err(|error| error.to_string())?;

    loop {
        let mut header = [0u8; 2];
        stream.read_exact(&mut header).map_err(|error| error.to_string())?;
        let opcode = header[0] & 0x0f;
        let masked = header[1] & 0x80 != 0;
        let mut length = (header[1] & 0x7f) as u64;
        if length == 126 {
            let mut ext = [0u8; 2];
            stream.read_exact(&mut ext).map_err(|error| error.to_string())?;
            length = u16::from_be_bytes(ext) as u64;
        } else if length == 127 {
            let mut ext = [0u8; 8];
            stream.read_exact(&mut ext).map_err(|error| error.to_string())?;
            length = u64::from_be_bytes(ext);
        }
        let mut mask = [0u8; 4];
        if masked {
            stream.read_exact(&mut mask).map_err(|error| error.to_string())?;
        }
        let mut data = vec![0u8; length as usize];
        stream.read_exact(&mut data).map_err(|error| error.to_string())?;
        if masked {
            for index in 0..data.len() {
                data[index] ^= mask[index % 4];
            }
        }
        match opcode {
            0x1 => return Ok(String::from_utf8_lossy(&data).to_string()),
            0x8 => return Err("ws_closed".into()),
            _ => continue, // ping/pong/binary/continuation
        }
    }
}

fn random_bytes(count: usize) -> Vec<u8> {
    let mut state = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0x9e37_79b9_7f4a_7c15);
    (0..count)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            (state & 0xff) as u8
        })
        .collect()
}

fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(TABLE[((n >> 18) & 63) as usize] as char);
        out.push(TABLE[((n >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 { TABLE[((n >> 6) & 63) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[(n & 63) as usize] as char } else { '=' });
    }
    out
}
