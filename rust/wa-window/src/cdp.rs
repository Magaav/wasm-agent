//! Chrome DevTools Protocol for the client machine.
//!
//! Everything about *finding* a browser and *talking* to it lives here, so the
//! executor in `client.rs` stays a dispatcher and every rule below is testable
//! without a window.
//!
//! Four rules, each of which was learned by breaking it:
//!
//! 1. **A port is not a browser.** 9222 is a convention, not a fact: another
//!    process can hold it, another Chrome can hold it for a *different* profile,
//!    and Chrome itself can end up on only one loopback stack. So the port is
//!    probed on both stacks, and what answers must *prove* it is DevTools
//!    (`/json/version` with a `webSocketDebuggerUrl`), never merely "a port
//!    answered". A node was left running on 127.0.0.1:9222 once; it answered 404
//!    to `/json/version`, the old probe could not tell that from silence, and
//!    every CDP call then spent 35s failing.
//! 2. **Launching is not idempotent, so it must not be a guess.** If Chrome for
//!    this profile is already up, attach. If the requested port is held by
//!    something else, do not fight it: ask Chrome for an ephemeral port (`0`)
//!    and read the port it chose from `<profile>/DevToolsActivePort` — the one
//!    place Chrome states the truth. The chosen port travels in every result.
//! 3. **A launch that hands off is a failure, not a wait.** Starting a second
//!    Chrome on a profile that is already open makes it exit immediately; the
//!    old code then polled for 35s. The child is watched, and an early exit is
//!    reported as the cause instead of as a timeout.
//! 4. **The result says where it acted.** Chrome restores tabs on start, so
//!    "the first page target" is an arbitrary tab. Targets are addressed by id,
//!    the one used is remembered, and every result names it.
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, TcpStream, ToSocketAddrs};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// The conventional port. Asked for when it is free, never assumed.
const DEFAULT_CDP_PORT: u16 = 9222;
/// How long a *first* launch of a large profile is given. The caller's budget
/// can shorten it; nothing here outlives the caller's patience.
const LAUNCH_WAIT_MS: u64 = 40_000;
/// Probes are cheap and must stay cheap: an endpoint that accepts a connection
/// and then says nothing costs this much, not the request timeout.
const PROBE_TIMEOUT_MS: u64 = 1200;
/// `/json/*` requests answer in milliseconds.
const REQUEST_TIMEOUT_MS: u64 = 15_000;

pub(crate) fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn local_app_data() -> PathBuf {
    std::env::var("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."))
}

/// Where this client keeps its own small state (not the node's state).
pub(crate) fn state_dir() -> PathBuf {
    let dir = local_app_data().join("wasm-agent");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn state_path() -> PathBuf {
    state_dir().join("cdp-state.json")
}

fn launch_log_path() -> PathBuf {
    state_dir().join("chrome-launch.log")
}

fn default_profile() -> String {
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        return format!("{local}\\AgentBrowserChromeProfile");
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    format!("{home}/.wasm-agent/chrome")
}

// ---- stats: what this client has been doing, without asking the network --------

#[derive(Default)]
struct Stats {
    started_ms: u64,
    actions: u64,
    last_action: Option<String>,
    last_ok: Option<bool>,
    last_error: Option<String>,
    last_ms: Option<u64>,
    launches: u64,
    poll_ok: u64,
    poll_failures: u64,
    last_poll_age_ms: Option<u64>,
}

static STATS: std::sync::Mutex<Option<Stats>> = std::sync::Mutex::new(None);

fn with_stats<T>(f: impl FnOnce(&mut Stats) -> T) -> T {
    let mut guard = match STATS.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    let stats = guard.get_or_insert_with(|| Stats { started_ms: now_ms(), ..Default::default() });
    f(stats)
}

/// Called by the executor after every command, so `status` reports history
/// rather than only the present.
pub(crate) fn note_action(action: &str, ok: bool, ms: u64, error: Option<&str>) {
    with_stats(|stats| {
        stats.actions += 1;
        stats.last_action = Some(action.to_string());
        stats.last_ok = Some(ok);
        stats.last_ms = Some(ms);
        stats.last_error = error.map(str::to_string);
    });
}

pub(crate) fn note_poll(ok: bool) {
    with_stats(|stats| match ok {
        true => {
            stats.poll_ok += 1;
            stats.poll_failures = 0;
            stats.last_poll_age_ms = Some(0);
        }
        false => {
            stats.poll_failures += 1;
            stats.last_poll_age_ms = Some(now_ms().saturating_sub(stats.started_ms));
        }
    });
}

fn note_launch() {
    with_stats(|stats| stats.launches += 1);
}

fn stats_json() -> Value {
    with_stats(|stats| {
        json!({
            "started_ms": stats.started_ms,
            "uptime_ms": now_ms().saturating_sub(stats.started_ms),
            "actions": stats.actions,
            "last_action": stats.last_action,
            "last_ok": stats.last_ok,
            "last_error": stats.last_error,
            "last_ms": stats.last_ms,
            "launches": stats.launches,
            "polls_ok": stats.poll_ok,
            "poll_failures": stats.poll_failures,
        })
    })
}

// ---- our own memory of where the browser is -----------------------------------

#[derive(Default, Clone)]
struct State {
    port: Option<u16>,
    host: Option<String>,
    browser: Option<String>,
    profile: Option<String>,
    last_target: Option<String>,
    last_url: Option<String>,
    last_title: Option<String>,
}

fn load_state() -> State {
    let Ok(text) = std::fs::read_to_string(state_path()) else { return State::default() };
    let Ok(value) = serde_json::from_str::<Value>(&text) else { return State::default() };
    State {
        port: value["port"].as_u64().map(|v| v as u16),
        host: value["host"].as_str().map(str::to_string),
        browser: value["browser"].as_str().map(str::to_string),
        profile: value["profile"].as_str().map(str::to_string),
        last_target: value["last_target"].as_str().map(str::to_string),
        last_url: value["last_url"].as_str().map(str::to_string),
        last_title: value["last_title"].as_str().map(str::to_string),
    }
}

/// Best-effort: a client that cannot remember where its browser is must still
/// work, so a failed write is not an error, only a lost shortcut.
fn save_state(state: &State) {
    let value = json!({
        "port": state.port,
        "host": state.host,
        "browser": state.browser,
        "profile": state.profile,
        "last_target": state.last_target,
        "last_url": state.last_url,
        "last_title": state.last_title,
        "at_ms": now_ms(),
    });
    let _ = std::fs::write(state_path(), value.to_string());
}

fn profile_of(args: &Value) -> String {
    args["profile"].as_str().filter(|s| !s.is_empty()).map(str::to_string).unwrap_or_else(default_profile)
}

// ---- a very small HTTP client (localhost only) --------------------------------

fn connect_stack(host: &str, port: u16) -> std::io::Result<TcpStream> {
    // Both stacks are tried explicitly rather than by name: `localhost` on this
    // machine resolves to ::1 for one caller and 127.0.0.1 for another, and the
    // whole point here is to know *which* one answered.
    let address = if host.trim_matches(['[', ']']) == "::1" || host == "localhost" {
        if host == "localhost" {
            SocketAddr::from((Ipv4Addr::LOCALHOST, port))
        } else {
            SocketAddr::from((Ipv6Addr::LOCALHOST, port))
        }
    } else if host.trim_matches(['[', ']']) == "127.0.0.1" {
        SocketAddr::from((Ipv4Addr::LOCALHOST, port))
    } else {
        // Anything else (a named host) goes through the resolver.
        let mut resolved = (host, port).to_socket_addrs()?;
        resolved.next().ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "no address"))?
    };
    TcpStream::connect(address)
}



pub(crate) fn http(
    host: &str,
    port: u16,
    method: &str,
    path: &str,
    body: Option<&str>,
    timeout_ms: u64,
) -> Option<String> {
    let mut stream = connect_stack(host, port).ok()?;
    stream.set_read_timeout(Some(Duration::from_millis(timeout_ms))).ok()?;
    stream.set_write_timeout(Some(Duration::from_millis(timeout_ms))).ok()?;
    let payload = body.unwrap_or("");
    // HTTP/1.1: Chrome's DevTools endpoint refuses HTTP/1.0 requests.
    let request = format!(
        "{method} {path} HTTP/1.1\r\nHost: {host}:{port}\r\nContent-Type: application/json\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n{payload}",
        payload.len()
    );
    stream.write_all(request.as_bytes()).ok()?;

    // Headers first, then exactly Content-Length bytes: Chrome keeps the socket
    // open, so reading to EOF would block until the timeout.
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        if stream.read(&mut byte).ok()? == 0 {
            break;
        }
        head.push(byte[0]);
        if head.len() > 65536 {
            return None;
        }
    }
    let head_text = String::from_utf8_lossy(&head).to_ascii_lowercase();
    if !head_text.is_empty() && !head_text.starts_with("http/1.1 2") && !head_text.starts_with("http/1.0 2") {
        // A non-2xx answer is *information* (404 from a squatter), never data.
        return None;
    }
    let length = head_text.lines().find_map(|line| {
        line.strip_prefix("content-length:").and_then(|value| value.trim().parse::<usize>().ok())
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

fn http_json(host: &str, port: u16, method: &str, path: &str, body: Option<&str>, timeout_ms: u64) -> Option<Value> {
    serde_json::from_str(&http(host, port, method, path, body, timeout_ms)?).ok()
}

/// Is *anything* listening on this port, on either loopback stack?
/// Used only to choose a launch port: a busy port is never treated as an error,
/// it is a reason to ask Chrome for an ephemeral one.
fn port_busy(port: u16) -> bool {
    for host in ["127.0.0.1", "::1"] {
        if connect_stack(host, port).is_ok() {
            return true;
        }
    }
    false
}

// ---- identity: what answered, and is it ours? ---------------------------------

#[derive(Clone)]
struct Version {
    host: String,
    port: u16,
    browser: String,
    ws_url: String,
    /// `/devtools/browser/<uuid>` — the instance's own name for itself.
    path: String,
}

fn version_at(host: &str, port: u16) -> Option<Version> {
    let value = http_json(host, port, "GET", "/json/version", None, PROBE_TIMEOUT_MS)?;
    let ws_url = value["webSocketDebuggerUrl"].as_str()?.to_string();
    let (_, _, path) = parse_ws_url(&ws_url)?;
    Some(Version {
        host: host.to_string(),
        port,
        browser: value["Browser"].as_str().unwrap_or("unknown").to_string(),
        ws_url,
        path,
    })
}

/// The first endpoint that *proves* it is DevTools, on both loopback stacks.
/// `expect_path` pins it to one browser instance when we know which one we mean.
fn find_cdp(port: u16, expect_path: Option<&str>) -> Option<Version> {
    for host in ["127.0.0.1", "[::1]"] {
        if let Some(version) = version_at(host, port) {
            let ours = expect_path.map(|expected| expected == version.path).unwrap_or(true);
            if ours {
                return Some(version);
            }
        }
    }
    None
}

/// Chrome writes `port\n/devtools/browser/<uuid>\n` into the profile when it is
/// started with `--remote-debugging-port=0`. It is the only place the chosen port
/// is stated, so it is read, not guessed.
fn devtools_active_port(profile: &str) -> Option<(u16, String)> {
    let text = std::fs::read_to_string(PathBuf::from(profile).join("DevToolsActivePort")).ok()?;
    let mut lines = text.lines().filter(|line| !line.trim().is_empty());
    let port: u16 = lines.next()?.trim().parse().ok()?;
    let path = lines.next().unwrap_or("").trim().to_string();
    Some((port, path))
}

fn parse_ws_url(url: &str) -> Option<(String, u16, String)> {
    let rest = url.strip_prefix("ws://").or_else(|| url.strip_prefix("wss://"))?;
    let (authority, path) = match rest.find('/') {
        Some(index) => (&rest[..index], rest[index..].to_string()),
        None => (rest, "/".to_string()),
    };
    // `ws://[::1]:9222/...` — the brackets are part of the URL, not the host.
    if let Some(close) = authority.find(']') {
        let host = authority[..=close].to_string();
        let port = authority[close + 1..].strip_prefix(':').and_then(|v| v.parse().ok()).unwrap_or(80);
        return Some((host, port, path));
    }
    match authority.rsplit_once(':') {
        Some((host, port)) => Some((host.to_string(), port.parse().ok()?, path)),
        None => Some((authority.to_string(), 80, path)),
    }
}

// ---- the resolved endpoint, as the caller sees it -----------------------------

struct Cdp {
    version: Version,
    profile: String,
    requested_port: Option<u16>,
    launched: bool,
    source: &'static str,
    notes: Vec<String>,
}

impl Cdp {
    fn json(&self) -> Value {
        json!({
            "running": true,
            "port": self.version.port,
            "host": self.version.host,
            "browser": self.version.browser,
            "profile": self.profile,
            "launched": self.launched,
            "requested_port": self.requested_port,
            "source": self.source,
            "notes": self.notes,
        })
    }
}

fn failure(error: &str, observed: &str, next: &str, extra: Value) -> Value {
    let mut value = json!({ "error": error, "observed": observed, "next": next });
    if let (Some(map), Some(more)) = (value.as_object_mut(), extra.as_object()) {
        for (key, item) in more {
            map.insert(key.clone(), item.clone());
        }
    }
    value
}

/// Record where the browser is, so the next call is a single probe rather than
/// the whole ladder. Best effort: losing this costs speed, never correctness.
fn save_where(profile: &str, version: &Version) {
    let mut state = load_state();
    state.port = Some(version.port);
    state.host = Some(version.host.clone());
    state.browser = Some(version.browser.clone());
    state.profile = Some(profile.to_string());
    save_state(&state);
}

/// The one exit from `resolve`, so every path records the endpoint it found.
fn found(version: Version, profile: &str, requested: Option<u16>, launched: bool, source: &'static str, notes: Vec<String>) -> Result<Cdp, Value> {
    save_where(profile, &version);
    Ok(Cdp { version, profile: profile.to_string(), requested_port: requested, launched, source, notes })
}

/// Find the browser for this profile, launching one only if there is none.
///
/// The order *is* the fix. Only two things prove an endpoint belongs to this
/// profile: our own record of where we left it, and the port Chrome wrote into
/// the profile. An endpoint that merely answers on the conventional port proves
/// nothing — adopting one turned out to be adoptable across profiles, which a
/// test caught by adopting a *different* profile's browser on 9222:
///
/// 1. where we last saw it, if that still answers;
/// 2. the port the profile itself names, matched by the browser's own id;
/// 3. the port the caller named (an explicit port is a statement of intent);
/// 4. the convention — only for *this client's own* account profile, which is
///    ours by definition, and never for a profile the caller supplied;
/// 5. otherwise launch, on a port Chrome picks and reports.
fn resolve(profile: &str, requested: Option<u16>, budget_ms: u64) -> Result<Cdp, Value> {
    let mut notes: Vec<String> = Vec::new();
    let ours_by_default = profile == default_profile();

    // 1. Our own record of where the browser was.
    let state = load_state();
    if state.profile.as_deref() == Some(profile) {
        if let Some(port) = state.port {
            if let Some(version) = find_cdp(port, None) {
                return found(version, profile, requested, false, "state", notes);
            }
        }
    }

    // 2. The profile's own record of the port it chose, pinned by instance id.
    let active = devtools_active_port(profile);
    if let Some((port, ws_path)) = active.clone() {
        if let Some(version) = find_cdp(port, Some(&ws_path)) {
            return found(version, profile, requested, false, "profile-file", notes);
        }
    }

    // 3. The port the caller named.
    if let Some(port) = requested {
        if let Some(version) = find_cdp(port, None) {
            return found(version, profile, requested, false, "requested", notes);
        }
        if port_busy(port) {
            notes.push(format!("port {port} is held by something that is not Chrome DevTools"));
        } else {
            notes.push(format!("nothing was listening on the requested port {port}"));
        }
    } else if ours_by_default {
        // 4. The convention, for our own account only.
        if let Some(version) = find_cdp(DEFAULT_CDP_PORT, None) {
            notes.push(format!("using the browser already on {DEFAULT_CDP_PORT} (this client's own Chrome account)"));
            return found(version, profile, requested, false, "default", notes);
        }
        if port_busy(DEFAULT_CDP_PORT) {
            notes.push(format!("port {DEFAULT_CDP_PORT} is held by something that is not Chrome DevTools"));
        }
    } else if port_busy(DEFAULT_CDP_PORT) {
        notes.push(format!("port {DEFAULT_CDP_PORT} is busy; this profile gets a port of Chrome's choosing"));
    }

    // 5. Launch. A port Chrome picks when the wanted one is taken, so a squatter
    // can never make a launch fail — the chosen port comes back in the result.
    let launch_port = match requested {
        Some(port) if !port_busy(port) => port,
        None if !port_busy(DEFAULT_CDP_PORT) => DEFAULT_CDP_PORT,
        _ => 0,
    };
    if launch_port == 0 {
        notes.push(format!(
            "asked Chrome for an ephemeral port instead of {}",
            requested.unwrap_or(DEFAULT_CDP_PORT)
        ));
    }
    let mut child = launch(profile, launch_port, &mut notes)?;

    let deadline = Instant::now() + Duration::from_millis(budget_ms.min(LAUNCH_WAIT_MS + 3_000));
    let mut last_error = "no DevTools endpoint appeared".to_string();
    while Instant::now() < deadline {
        // A second Chrome on an already-open profile hands off and exits. That is
        // an answer, and it arrives in under a second: report it as itself rather
        // than as a timeout thirty-five seconds later.
        if let Ok(Some(status)) = child.try_wait() {
            if find_cdp(launch_port, None).is_none() && devtools_active_port(profile).is_none() {
                return Err(failure(
                    "chrome_handed_off",
                    &format!(
                        "the Chrome that was started exited at once ({status}) without opening a DevTools port: \
                         the profile {profile} is already open in another Chrome process"
                    ),
                    "quit that Chrome (or pass its port explicitly, e.g. port:9222, if it has remote debugging), \
                     or use a different profile",
                    json!({ "profile": profile, "requested_port": requested, "notes": notes,
                            "chrome_log": log_tail(&launch_log_path(), 6) }),
                ));
            }
        }
        if let Some((port, ws_path)) = devtools_active_port(profile) {
            if let Some(version) = find_cdp(port, Some(&ws_path)) {
                return found(version, profile, requested, true, "launched", notes);
            }
            last_error = format!("DevToolsActivePort names port {port}, but nothing answers there");
        }
        if launch_port != 0 {
            if let Some(version) = find_cdp(launch_port, None) {
                return found(version, profile, requested, true, "launched", notes);
            }
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    Err(failure(
        "chrome_start_timeout",
        &format!("launched Chrome for {profile} and waited {}ms; {last_error}", budget_ms.min(LAUNCH_WAIT_MS + 3_000)),
        "retry with a larger timeout_ms (a first launch of a large profile is slow), or check the launch log",
        json!({ "profile": profile, "requested_port": requested, "notes": notes,
                "chrome_log": log_tail(&launch_log_path(), 6) }),
    ))
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

/// Start Chrome and hand back the child, so the caller can watch it: a second
/// Chrome on an already-open profile exits at once, and saying so in one second
/// beats polling for thirty-five.
fn launch(profile: &str, port: u16, notes: &mut Vec<String>) -> Result<Child, Value> {
    let Some(chrome) = find_chrome() else {
        return Err(failure(
            "chrome_not_found",
            "no chrome.exe under PROGRAMFILES, ProgramFiles(x86) or LOCALAPPDATA",
            "install Chrome on this machine, or pass the profile/port of an existing DevTools endpoint",
            json!({}),
        ));
    };
    let mut command = Command::new(&chrome);
    command
        .arg(format!("--remote-debugging-port={port}"))
        .arg(format!("--user-data-dir={profile}"))
        .arg("--no-first-run")
        .arg("--no-default-browser-check")
        .arg("--restore-last-session")
        .arg("about:blank");
    // An escape hatch for the cases this file cannot know about: `--headless=new`
    // on a machine with no desktop, a proxy, an extension. Space-separated.
    if let Ok(extra) = std::env::var("WASM_AGENT_CHROME_ARGS") {
        for argument in extra.split_whitespace() {
            command.arg(argument);
        }
    }
    // Chrome's own account of a failed start is the only account there is, so it
    // is kept rather than discarded.
    if let Ok(file) = std::fs::File::create(launch_log_path()) {
        command.stdout(Stdio::null()).stderr(Stdio::from(file));
    } else {
        command.stdout(Stdio::null()).stderr(Stdio::null());
    }
    let child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            return Err(failure(
                "chrome_launch_failed",
                &format!("spawning {chrome} failed: {error}"),
                "check that Chrome runs as this user",
                json!({ "chrome": chrome }),
            ))
        }
    };
    note_launch();
    notes.push(format!("launched Chrome on port {port}"));
    Ok(child)
}

fn log_tail(path: &std::path::Path, lines: usize) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let tail: Vec<&str> = text.lines().rev().take(lines).collect();
    if tail.is_empty() {
        return None;
    }
    Some(tail.into_iter().rev().collect::<Vec<_>>().join("\n"))
}

// ---- targets -------------------------------------------------------------------

fn targets(version: &Version) -> Option<Vec<Value>> {
    let value = http_json(&version.host, version.port, "GET", "/json/list", None, REQUEST_TIMEOUT_MS)?;
    value.as_array().cloned()
}

fn is_page(target: &Value) -> bool {
    target["type"].as_str() == Some("page")
}

/// Pages only: `chrome://omnibox-popup` and friends are browser furniture, and
/// listing them buries the tabs a caller means.
fn pages(all: &[Value]) -> Vec<Value> {
    all.iter().filter(|target| is_page(target)).cloned().collect()
}

fn pick_target(list: &[Value], id: Option<&str>, last: Option<&str>) -> Option<Value> {
    let pages = pages(list);
    if let Some(id) = id {
        if let Some(found) = list.iter().find(|target| target["id"].as_str() == Some(id)) {
            return Some(found.clone());
        }
    }
    if let Some(last) = last {
        if let Some(found) = pages.iter().find(|target| target["id"].as_str() == Some(last)) {
            return Some(found.clone());
        }
    }
    // A restored session starts on about:blank; a real page is the better default.
    if let Some(found) = pages.iter().find(|target| {
        !matches!(target["url"].as_str(), Some("about:blank") | Some("") | None)
    }) {
        return Some(found.clone());
    }
    pages.first().cloned()
}

fn target_summary(target: &Value) -> Value {
    json!({
        "id": target["id"],
        "url": target["url"],
        "title": target["title"],
        "type": target["type"],
    })
}

/// `/json/new` takes the URL as a bare, percent-encoded query string. Passing
/// `?url=<url>` yields `about:blank`, which is exactly what it looks like.
fn urlencode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(byte as char),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn open_target(version: &Version, url: &str) -> Option<Value> {
    let body = http(&version.host, version.port, "PUT", &format!("/json/new?{}", urlencode(url)), None, REQUEST_TIMEOUT_MS)?;
    serde_json::from_str(&body).ok()
}

fn close_target(version: &Version, id: &str) -> Option<String> {
    http(&version.host, version.port, "GET", &format!("/json/close/{id}"), None, REQUEST_TIMEOUT_MS)
}

fn activate_target(version: &Version, id: &str) -> Option<String> {
    http(&version.host, version.port, "GET", &format!("/json/activate/{id}"), None, REQUEST_TIMEOUT_MS)
}

/// Ask the browser to close. The normal path is to leave it running so the next
/// call attaches to it; this exists for the case where the node wants the
/// browser it started to be gone (a test, or a one-off task on someone's desk).
fn browser_close(version: &Version) -> Result<(), String> {
    let message = json!({ "id": 1, "method": "Browser.close" }).to_string();
    ws_call(&version.ws_url, &message, 5_000).map(|_| ())
}

fn target_ws(_version: &Version, target: &Value) -> Option<String> {
    target["webSocketDebuggerUrl"].as_str().map(str::to_string)
}

// ---- CDP over a WebSocket ------------------------------------------------------

fn ws_call(url: &str, message: &str, timeout_ms: u64) -> Result<String, String> {
    let (host, port, path) = parse_ws_url(url).ok_or_else(|| format!("bad_ws_url:{url}"))?;
    let mut stream = connect_stack(&host, port).map_err(|error| error.to_string())?;
    stream.set_read_timeout(Some(Duration::from_millis(timeout_ms))).ok();

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

fn ws_eval(url: &str, expression: &str, timeout_ms: u64) -> Result<Value, String> {
    let message = json!({
        "id": 1,
        "method": "Runtime.evaluate",
        "params": { "expression": expression, "returnByValue": true, "awaitPromise": true }
    })
    .to_string();
    let response = ws_call(url, &message, timeout_ms)?;
    let parsed: Value = serde_json::from_str(&response).map_err(|error| error.to_string())?;
    if let Some(error) = parsed["error"].as_object() {
        return Err(format!("cdp_error:{error:?}"));
    }
    Ok(parsed["result"]["result"].clone())
}

fn ws_navigate(url: &str, page_url: &str, timeout_ms: u64) -> Result<Value, String> {
    let message = json!({
        "id": 1,
        "method": "Page.navigate",
        "params": { "url": page_url }
    })
    .to_string();
    let response = ws_call(url, &message, timeout_ms)?;
    let parsed: Value = serde_json::from_str(&response).map_err(|error| error.to_string())?;
    if let Some(error) = parsed["error"].as_object() {
        return Err(format!("cdp_error:{error:?}"));
    }
    Ok(parsed["result"].clone())
}

/// Wait until the target says it is done loading. A page that never finishes is
/// reported as `ready:false` with the state it is in, never as a hang.
fn wait_loaded(version: &Version, target: &Value, budget_ms: u64) -> Value {
    let Some(url) = target_ws(version, target) else {
        return json!({ "ready": false, "reason": "no_ws_url" });
    };
    let deadline = Instant::now() + Duration::from_millis(budget_ms);
    let mut last = json!({ "ready": false, "reason": "no_answer" });
    while Instant::now() < deadline {
        match ws_eval(
            &url,
            "JSON.stringify({ready: document.readyState, url: location.href, title: document.title})",
            5_000,
        ) {
            Ok(value) => {
                let text = value.as_str().unwrap_or("{}").to_string();
                let parsed: Value = serde_json::from_str(&text).unwrap_or(json!({}));
                let ready = parsed["ready"].as_str() == Some("complete");
                last = json!({
                    "ready": ready,
                    "state": parsed["ready"],
                    "url": parsed["url"],
                    "title": parsed["title"],
                });
                if ready {
                    return last;
                }
            }
            Err(error) => last = json!({ "ready": false, "reason": error }),
        }
        std::thread::sleep(Duration::from_millis(400));
    }
    last
}

// ---- percent of a URL that identifies it (for reuse) ---------------------------

fn same_page(left: &str, right: &str) -> bool {
    let norm = |text: &str| {
        let trimmed = text.trim_end_matches('/');
        trimmed.split('#').next().unwrap_or("").to_string()
    };
    !left.is_empty() && norm(left) == norm(right)
}

// ---- the fluent surface --------------------------------------------------------

fn page_result(cdp: &Cdp, target: &Value, loaded: Option<Value>) -> Value {
    let mut page = target_summary(target);
    if let (Some(map), Some(loaded)) = (page.as_object_mut(), loaded.as_ref().and_then(Value::as_object)) {
        for key in ["ready", "state", "title", "url"] {
            if let Some(value) = loaded.get(key) {
                if key == "title" || key == "url" {
                    map.insert(key.to_string(), value.clone());
                }
            }
        }
    }
    json!({ "ok": true, "page": page, "chrome": cdp.json() })
}

/// Remember which tab we last worked in, so the next call acts on it rather than
/// on whichever target Chrome happens to list first.
fn remember(cdp: &Cdp, target: &Value, title: Option<&str>) {
    let mut state = load_state();
    state.port = Some(cdp.version.port);
    state.host = Some(cdp.version.host.clone());
    state.browser = Some(cdp.version.browser.clone());
    state.profile = Some(cdp.profile.clone());
    state.last_target = target["id"].as_str().map(str::to_string);
    state.last_url = target["url"].as_str().map(str::to_string);
    if let Some(title) = title {
        state.last_title = Some(title.to_string());
    }
    save_state(&state);
}

fn browser_action(args: &Value, budget_ms: u64) -> Value {
    let profile = profile_of(args);
    let target_action = args["target"].as_str().unwrap_or("list");
    let cdp = match resolve(&profile, args["port"].as_i64().map(|v| v as u16), budget_ms) {
        Ok(cdp) => cdp,
        Err(error) => return error,
    };
    let state = load_state();
    match target_action {
        "list" => {
            let Some(all) = targets(&cdp.version) else {
                return failure("cdp_unreachable", "the DevTools endpoint stopped answering", "retry", json!({"chrome": cdp.json()}));
            };
            json!({
                "ok": true,
                "pages": pages(&all).iter().map(target_summary).collect::<Vec<_>>(),
                "chrome": cdp.json(),
            })
        }
        "open" | "navigate" => {
            let url = args["url"].as_str().unwrap_or("about:blank");
            let reuse = args["reuse"].as_bool().unwrap_or(true);
            let all = targets(&cdp.version).unwrap_or_default();
            let existing = if reuse { pages(&all).into_iter().find(|p| same_page(p["url"].as_str().unwrap_or(""), url)) } else { None };
            let (target, opened) = match existing {
                Some(found) => (found, false),
                None => {
                    let Some(created) = open_target(&cdp.version, url) else {
                        return failure("cdp_open_failed", &format!("PUT /json/new for {url} failed"), "retry, or pass a specific target id", json!({"chrome": cdp.json()}));
                    };
                    (created, true)
                }
            };
            let loaded = if url == "about:blank" { None } else { Some(wait_loaded(&cdp.version, &target, budget_ms.min(15_000))) };
            if let Some(loaded) = loaded.as_ref() {
                let actual_url = loaded["url"].as_str().unwrap_or_default();
                if !same_page(actual_url, url) {
                    return failure(
                        "navigation_redirected",
                        &format!("requested {url}, but the browser ended at {actual_url}"),
                        "inspect the redirect or authentication state; retry only after confirming the destination",
                        json!({ "requested_url": url, "actual_url": actual_url, "page_id": target["id"], "chrome": cdp.json() }),
                    );
                }
            }
            remember(&cdp, &target, loaded.as_ref().and_then(|v| v["title"].as_str()));
            let mut result = page_result(&cdp, &target, loaded);
            result["opened"] = json!(opened);
            if let Some(map) = result["page"].as_object_mut() {
                map.insert("id".into(), target["id"].clone());
                // A single-tab operation still needs the id to be usable later.
                map.insert("handle".into(), target["id"].clone());
            }
            result
        }
        "read" => {
            let all = targets(&cdp.version).unwrap_or_default();
            let Some(target) = pick_target(&all, args["id"].as_str(), state.last_target.as_deref()) else {
                return failure("no_page_target", "no page tab is open in this browser", "browser {target:'open', url:'...'}", json!({"chrome": cdp.json()}));
            };
            let max = args["max_chars"].as_i64().unwrap_or(2_000).clamp(200, 20_000);
            let expression = format!(
                "(() => {{ const t = document.body ? document.body.innerText : ''; \
                 return JSON.stringify({{text: t.slice(0, {max}), truncated: t.length > {max}, title: document.title, url: location.href}}); }})()"
            );
            let Some(ws) = target_ws(&cdp.version, &target) else {
                return failure("no_ws_url", "the target has no WebSocket debugger URL", "list the targets and pick another", json!({}));
            };
            match ws_eval(&ws, &expression, REQUEST_TIMEOUT_MS) {
                Ok(value) => {
                    let parsed: Value = serde_json::from_str(value.as_str().unwrap_or("{}")).unwrap_or(json!({}));
                    remember(&cdp, &target, parsed["title"].as_str());
                    json!({
                        "ok": true,
                        "page": { "id": target["id"], "url": parsed["url"], "title": parsed["title"] },
                        "text": parsed["text"],
                        "truncated": parsed["truncated"],
                        "chrome": cdp.json(),
                    })
                }
                Err(error) => failure("evaluate_failed", &error, "retry, or use browser {target:'list'}", json!({"chrome": cdp.json()})),
            }
        }
        "eval" => {
            let all = targets(&cdp.version).unwrap_or_default();
            let Some(target) = pick_target(&all, args["id"].as_str(), state.last_target.as_deref()) else {
                return failure("no_page_target", "no page tab is open", "browser {target:'open', url:'...'}", json!({"chrome": cdp.json()}));
            };
            let script = args["script"].as_str().or_else(|| args["text"].as_str()).unwrap_or("");
            let Some(ws) = target_ws(&cdp.version, &target) else {
                return failure("no_ws_url", "the target has no WebSocket debugger URL", "list the targets", json!({}));
            };
            match ws_eval(&ws, script, REQUEST_TIMEOUT_MS) {
                Ok(value) => {
                    remember(&cdp, &target, None);
                    json!({ "ok": true, "page": {"id": target["id"], "url": target["url"]}, "value": value, "chrome": cdp.json() })
                }
                Err(error) => failure("evaluate_failed", &error, "check the script; a syntax error is returned here", json!({"chrome": cdp.json()})),
            }
        }
        "close" => {
            let id = args["id"].as_str().unwrap_or_default();
            if id.is_empty() {
                return failure("id_required", "close needs the target id", "browser {target:'list'}", json!({"chrome": cdp.json()}));
            }
            match close_target(&cdp.version, id) {
                Some(body) => json!({ "ok": true, "closed": id, "result": body.trim(), "chrome": cdp.json() }),
                None => failure("cdp_close_failed", &format!("no answer closing {id}"), "list the targets; the id may be stale", json!({"chrome": cdp.json()})),
            }
        }
        "activate" => {
            let id = args["id"].as_str().unwrap_or_default();
            match activate_target(&cdp.version, id) {
                Some(body) => json!({ "ok": true, "activated": id, "result": body.trim(), "chrome": cdp.json() }),
                None => failure("cdp_activate_failed", &format!("no answer activating {id}"), "list the targets; the id may be stale", json!({"chrome": cdp.json()})),
            }
        }
        // Everything the browser had open goes with it; the next call starts a new
        // one, on a port Chrome picks.
        "quit" | "stop" => match browser_close(&cdp.version) {
            Ok(()) => json!({ "ok": true, "closed_browser": cdp.json() }),
            Err(error) => failure("browser_close_failed", &error, "the browser may already be gone", json!({"chrome": cdp.json()})),
        },
        other => failure("unknown_target", &format!("browser target '{other}' is not one of list/open/read/eval/close/activate/quit"), "use one of those", json!({})),
    }
}

/// The low-level action, kept shape-compatible with what callers already send:
/// `chrome` is still the block about the browser, and `{target:'launch'}` still
/// means "make sure one is up".
fn cdp_action(args: &Value, budget_ms: u64) -> Value {
    let profile = profile_of(args);
    let requested = args["port"].as_i64().map(|value| value as u16);
    let target_action = args["target"].as_str().unwrap_or("list");
    let cdp = match resolve(&profile, requested, budget_ms) {
        Ok(cdp) => cdp,
        Err(error) => return error,
    };
    match target_action {
        "launch" => json!({ "ok": true, "running": true, "chrome": cdp.json() }),
        "list" => {
            let Some(all) = targets(&cdp.version) else {
                return failure("cdp_unreachable", "the DevTools endpoint stopped answering", "retry", json!({"chrome": cdp.json()}));
            };
            json!({
                "ok": true,
                "targets": all.iter().map(target_summary).collect::<Vec<_>>(),
                "chrome": cdp.json(),
            })
        }
        "open" => {
            let url = args["url"].as_str().unwrap_or("about:blank");
            match open_target(&cdp.version, url) {
                Some(target) => {
                    remember(&cdp, &target, None);
                    page_result(&cdp, &target, None)
                }
                None => failure("cdp_open_failed", &format!("PUT /json/new for {url} failed"), "retry", json!({"chrome": cdp.json()})),
            }
        }
        "close" => {
            let id = args["id"].as_str().unwrap_or_default();
            match close_target(&cdp.version, id) {
                Some(body) => json!({ "ok": true, "closed": body.trim(), "chrome": cdp.json() }),
                None => failure("cdp_close_failed", &format!("no answer closing {id}"), "list the targets", json!({"chrome": cdp.json()})),
            }
        }
        "activate" => {
            let id = args["id"].as_str().unwrap_or_default();
            match activate_target(&cdp.version, id) {
                Some(body) => json!({ "ok": true, "activated": body.trim(), "chrome": cdp.json() }),
                None => failure("cdp_activate_failed", &format!("no answer activating {id}"), "list the targets", json!({"chrome": cdp.json()})),
            }
        }
        "navigate" => {
            let url = args["url"].as_str().unwrap_or("about:blank");
            let state = load_state();
            let all = targets(&cdp.version).unwrap_or_default();
            let Some(target) = pick_target(&all, args["id"].as_str(), state.last_target.as_deref()) else {
                return failure("no_page_target", "no page tab is open", "cdp {target:'open', url:'...'}", json!({"chrome": cdp.json()}));
            };
            let Some(ws) = target_ws(&cdp.version, &target) else {
                return failure("no_ws_url", "the target has no WebSocket debugger URL", "list the targets", json!({}));
            };
            match ws_navigate(&ws, url, REQUEST_TIMEOUT_MS) {
                Ok(result) => {
                    let loaded = wait_loaded(&cdp.version, &target, budget_ms.min(15_000));
                    remember(&cdp, &target, loaded["title"].as_str());
                    json!({ "ok": true, "navigated": url, "page": {"id": target["id"], "url": loaded["url"], "title": loaded["title"], "ready": loaded["ready"]}, "nav": result, "chrome": cdp.json() })
                }
                Err(error) => failure("navigate_failed", &error, "check the URL", json!({"chrome": cdp.json()})),
            }
        }
        "evaluate" => {
            let script = args["script"].as_str().or_else(|| args["text"].as_str()).unwrap_or("");
            let state = load_state();
            let all = targets(&cdp.version).unwrap_or_default();
            let Some(target) = pick_target(&all, args["id"].as_str(), state.last_target.as_deref()) else {
                return failure("no_page_target", "no page tab is open", "cdp {target:'open', url:'...'}", json!({"chrome": cdp.json()}));
            };
            let Some(ws) = target_ws(&cdp.version, &target) else {
                return failure("no_ws_url", "the target has no WebSocket debugger URL", "list the targets", json!({}));
            };
            match ws_eval(&ws, script, REQUEST_TIMEOUT_MS) {
                Ok(value) => {
                    remember(&cdp, &target, None);
                    json!({ "ok": true, "value": value, "target": target["id"], "chrome": cdp.json() })
                }
                Err(error) => failure("evaluate_failed", &error, "check the script", json!({"chrome": cdp.json()})),
            }
        }
        other => failure("unknown_target", &format!("cdp target '{other}' is not one of launch/list/open/close/activate/navigate/evaluate"), "use one of those, or the fluent `browser` action", json!({})),
    }
}

/// A cheap, complete answer to "what can this client do right now?", so nothing
/// has to be discovered by failing. No launch, one bounded probe at most.
pub(crate) fn status() -> Value {
    let state = load_state();
    let profile = state.profile.clone().unwrap_or_else(default_profile);
    let mut chrome = json!({ "running": false, "profile": profile });
    let started = Instant::now();
    // Probe where we last saw it, then the profile's own record: two ports at
    // most, and only if this client has ever met a browser.
    let mut candidates: Vec<u16> = Vec::new();
    if let Some(port) = state.port {
        candidates.push(port);
    }
    if let Some((port, _)) = devtools_active_port(&profile) {
        if !candidates.contains(&port) {
            candidates.push(port);
        }
    }
    for port in candidates {
        if let Some(version) = find_cdp(port, None) {
            chrome = json!({
                "running": true,
                "port": version.port,
                "host": version.host,
                "browser": version.browser,
                "profile": profile,
            });
            break;
        }
    }
    let pages_now = if chrome["running"] == json!(true) {
        let version = find_cdp(chrome["port"].as_u64().unwrap_or(0) as u16, None);
        version
            .and_then(|v| targets(&v))
            .map(|all| pages(&all).iter().map(target_summary).collect::<Vec<_>>())
    } else {
        None
    };
    json!({
        "ok": true,
        "client": stats_json(),
        "chrome": chrome,
        "pages": pages_now,
        "last_page": if state.last_target.is_some() {
            json!({ "id": state.last_target, "url": state.last_url, "title": state.last_title })
        } else {
            Value::Null
        },
        "probe_ms": started.elapsed().as_millis() as u64,
    })
}

fn launch_error_detail(profile: &str) -> Value {
    match log_tail(&launch_log_path(), 6) {
        Some(tail) => json!({ "profile": profile, "chrome_log": tail }),
        None => json!({ "profile": profile }),
    }
}

/// Entry point used by the executor. `budget_ms` is the caller's patience,
/// passed down so nothing here outlives it.
pub(crate) fn run(action: &str, args: &Value, budget_ms: u64) -> Value {
    let budget = budget_ms.clamp(1_000, 300_000);
    match action {
        "status" => status(),
        "browser" => browser_action(args, budget),
        "cdp" => {
            let result = cdp_action(args, budget);
            // A launch failure is common enough, and mysterious enough, to deserve
            // Chrome's own last words.
            if result["error"].as_str() == Some("chrome_start_timeout") {
                let profile = profile_of(args);
                let mut merged = result;
                if let (Some(map), Some(extra)) = (merged.as_object_mut(), launch_error_detail(&profile).as_object()) {
                    for (key, value) in extra {
                        map.insert(key.clone(), value.clone());
                    }
                }
                return merged;
            }
            result
        }
        other => failure("unknown_action", &format!("'{other}' is not handled by the cdp module"), "use cdp | browser | status", json!({})),
    }
}

// ---- helpers -------------------------------------------------------------------

fn random_bytes(count: usize) -> Vec<u8> {
    let mut state = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0x9e37_79b9_7f4a_7c15)
        ^ std::process::id() as u64;
    (0..count)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            (state & 0xff) as u8
        })
        .collect()
}

pub(crate) fn base64(bytes: &[u8]) -> String {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn ws_urls_parse_for_both_loopback_stacks() {
        let (host, port, path) = parse_ws_url("ws://[::1]:9222/devtools/browser/abc").unwrap();
        assert_eq!(host, "[::1]");
        assert_eq!(port, 9222);
        assert_eq!(path, "/devtools/browser/abc");
        // The form the old code failed on: the brackets are URL syntax, the host is ::1.


        let (host, port, _) = parse_ws_url("ws://127.0.0.1:9630/devtools/browser/abc").unwrap();
        assert_eq!((host.as_str(), port), ("127.0.0.1", 9630));
        assert!(parse_ws_url("http://127.0.0.1:1/x").is_none());
    }

    #[test]
    fn devtools_active_port_reads_the_file_chrome_writes() {
        let dir = std::env::temp_dir().join(format!("wa-cdp-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let file = dir.join("DevToolsActivePort");
        std::fs::write(&file, "9630\n/devtools/browser/999de45a\n").unwrap();
        let (port, path) = devtools_active_port(dir.to_str().unwrap()).unwrap();
        assert_eq!(port, 9630);
        assert_eq!(path, "/devtools/browser/999de45a");
        // No file at all is not a port.
        assert!(devtools_active_port(&dir.join("nothing").to_string_lossy()).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn json_new_needs_a_bare_encoded_query() {
        // `?url=https://x` yields about:blank: the URL is the whole query.
        assert_eq!(urlencode("https://web.whatsapp.com"), "https%3A%2F%2Fweb.whatsapp.com");
        assert_eq!(urlencode("https://a/b?c=d#e"), "https%3A%2F%2Fa%2Fb%3Fc%3Dd%23e");
        assert!(!urlencode("https://x.com").starts_with("url="));
    }

    #[test]
    fn a_page_is_preferred_over_a_restored_blank_tab() {
        let list = json!([
            {"id":"blank","type":"page","url":"about:blank","title":""},
            {"id":"omni","type":"browser_ui","url":"chrome://omnibox","title":"Omnibox"},
            {"id":"real","type":"page","url":"https://example.com/","title":"Example"}
        ]);
        let picked = pick_target(list.as_array().unwrap(), None, None).unwrap();
        assert_eq!(picked["id"], "real");
        // Our own memory wins over list order.
        let picked = pick_target(list.as_array().unwrap(), None, Some("blank")).unwrap();
        assert_eq!(picked["id"], "blank");
        // An explicit id always wins.
        let picked = pick_target(list.as_array().unwrap(), Some("omni"), Some("blank")).unwrap();
        assert_eq!(picked["id"], "omni");
    }

    #[test]
    fn a_busy_port_is_never_mistaken_for_a_browser() {
        // A squatter: accepts connections, answers 404 to everything. This is the
        // shape of the node that held 127.0.0.1:9222 and cost 35s per call.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        assert!(port_busy(port));
        assert!(find_cdp(port, None).is_none(), "404 must not pass as DevTools");
        drop(listener);
    }

    #[test]
    fn reuse_matches_the_page_we_meant() {
        assert!(same_page("https://web.whatsapp.com/", "https://web.whatsapp.com"));
        assert!(same_page("https://x.com/a#frag", "https://x.com/a"));
        assert!(!same_page("https://x.com/a", "https://x.com/b"));
        assert!(!same_page("https://chatgpt.com/", "https://chatgpt.com/share/abc"));
        assert!(!same_page("", "https://x.com/a"));
    }

    /// Opt-in: needs Chrome. Proves the launch path end to end on a throwaway
    /// profile, including that a second call reuses the browser instead of
    /// starting another one. Headless so it cannot put a window on someone's
    /// desk, and it closes what it started.
    ///
    ///     cargo test --release -- --ignored --nocapture
    #[test]
    #[ignore]
    fn live_launch_then_reuse() {
        std::env::set_var("WASM_AGENT_CHROME_ARGS", "--headless=new --disable-gpu");
        let dir = std::env::temp_dir().join(format!("wa-cdp-live-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::create_dir_all(&dir);
        let profile = dir.to_string_lossy().to_string();
        let first = resolve(&profile, None, 30_000).expect("first resolve must launch and find a browser");
        assert!(first.launched, "first call should have launched");
        assert!(first.version.port > 0);
        // The port Chrome chose is the port we report, and it is a real endpoint.
        assert!(find_cdp(first.version.port, Some(&first.version.path)).is_some());
        let second = resolve(&profile, None, 30_000).expect("second resolve must attach");
        assert!(!second.launched, "second call must reuse, not relaunch");
        assert_eq!(first.version.port, second.version.port);
        // A squatter on the port we would have asked for changes nothing: the
        // browser is found by identity, not by convention.
        let squat = TcpListener::bind("127.0.0.1:0").unwrap();
        let squat_port = squat.local_addr().unwrap().port();
        let third = resolve(&profile, Some(squat_port), 30_000).expect("a squatted port must not break discovery");
        assert_eq!(third.version.port, first.version.port);
        drop(squat);
        browser_close(&first.version).expect("the browser we started should close");
        std::env::remove_var("WASM_AGENT_CHROME_ARGS");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
