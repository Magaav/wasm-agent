//! The health probe: one HTTP/1.1 GET to `/health` over a loopback socket, and the honest answer to "did
//! it answer, and did it say it is well".
//!
//! A whole HTTP client crate was not worth it. What the watchdog needs is a GET on 127.0.0.1, no TLS, no
//! redirects, a hard timeout, and no reuse: the kernel closes the connection after a response and a
//! watchdog that keeps a socket open across a kernel swap would be holding a handle to a process it
//! replaced. Chunked transfer is decoded; anything else non-`Content-Length` is read to EOF, which is what
//! `Connection: close` promises.
//!
//! Readiness is deliberately strict and named: [`Probe::ready`] requires a 200 AND a top-level `"ok":true`.
//! A node that answers but says `ok:false` (a stalled run thread, a refused journal write) is *answering*
//! and *not ready*, and those two facts are different questions - the docs and the swap both need to be
//! able to tell them apart.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::{Duration, Instant};

use crate::json;

/// The body cap. `/health` is a few kilobytes; a peer that streams megabytes is not the kernel and must
/// not be able to make the watchdog allocate without bound.
const MAX_BODY: usize = 1024 * 1024;

/// THE SELF-WAKE RULE (r8c item G, approved 24/11): the node's own loop, from its own `/health.wakes`.
///
/// MEASURED on this laptop: the node delivered ZERO self-wakes for 2.5 hours (15:15Z-17:55Z) because its
/// tick raised before the claim loop, and NOTHING said so - `/health` answered `ok:true` throughout, and the
/// loopback canary stayed green because it runs a CHILD node with a fresh ledger. These four names are the
/// answer to "is this node's own loop alive", and `scripts/lib/health-wakes.sh` is the same rule for the
/// shell readers (checked against the same real bodies in both places).
///
/// A WAKE RED IS NOT A MISS (deliberate, and it is the line this file must not cross): [`Probe::ready`] is
/// what the supervisor uses to declare a kernel up and what a swap uses to decide it committed, and neither
/// may be turned by a wake the node owes itself. A node whose loop is dead is a node to REPORT, not to
/// restart under a running turn, and never a reason to roll back an install: restarting does not fix a
/// schema, and an install that put a good binary in place has not made the wake late. So the reds live in
/// [`Probe::wakes`] and in the status record, and `ready` does not read them.
#[derive(Debug, Clone, PartialEq)]
pub enum Wakes {
    /// The node cannot say what its wake state is (no `wakes` field, or no probe at all). Unknown is not yes.
    Unknown(String),
    /// NO TICK HAS PUBLISHED SINCE THIS NODE STARTED. An install judges exactly here - the rows that came due
    /// during the install are minutes old and the first tick has not dispatched yet - so this is neither green nor
    /// a red: the shell reader waits for the first tick (same verdict in scripts/lib/health-wakes.sh), and the
    /// watchdog reports the waiting line instead of calling a node that has been up for one second stalled.
    Waiting(String),
    /// Every red the body names, in the rule's fixed order. Empty would be green.
    Red(Vec<String>),
    /// Nothing is red: the one GREEN line, for a status that has to say something.
    Green(String),
}

impl Default for Wakes {
    fn default() -> Self {
        Wakes::Unknown("no probe has read /health yet".to_string())
    }
}

impl Wakes {
    /// The lines a reader prints: the GREEN line, every RED, or the UNKNOWN. Never empty.
    pub fn lines(&self) -> Vec<String> {
        match self {
            Wakes::Unknown(why) => vec![format!("UNKNOWN wakes: {why}")],
            Wakes::Waiting(why) => vec![format!("WAITING wakes: {why}")],
            Wakes::Red(reds) => reds.clone(),
            Wakes::Green(line) => vec![line.clone()],
        }
    }

    /// One line, for a status record that has one field for this.
    pub fn line(&self) -> String {
        self.lines().join(" | ")
    }

    pub fn is_green(&self) -> bool {
        matches!(self, Wakes::Green(_))
    }
}

/// `WA_WAKES_STALL_SECONDS`: how long a due, unheld row may wait with an idle lane before it is red.
pub const WAKE_STALL_SECONDS: u64 = 120;
/// `WA_WAKES_PUBLISH_SECONDS`: how stale the published facts may be before the publisher is considered gone.
pub const WAKE_PUBLISH_SECONDS: u64 = 30;

/// `/health` judged by the approved rule. One implementation for the product watchdog; the shell readers
/// run the same rule (scripts/lib/health-wakes.sh) and `scripts/test-health-wakes-rule.cjs` judges both
/// against the same real bodies.
pub fn wake_verdict(body: &str) -> Wakes {
    let wakes = match json::field(body, "wakes") {
        Some(value) if value.trim_start().starts_with('{') => value,
        _ => {
            return Wakes::Unknown(
                "/health has no wakes object (a node older than this rule, or a body that is not one)".to_string(),
            )
        }
    };
    // UNKNOWN IS NOT YES, FIELD BY FIELD: a field this rule reads that is not there is a red naming it, never a
    // skipped check (the shell judge does the same, and the two are held to the same bodies by a row).
    let missing = |field: &str| {
        Wakes::Red(vec![format!("RED wakes_unknown: {field} is missing from /health.wakes")])
    };
    match json::field_bool(wakes, "known") {
        Some(true) => {}
        Some(false) => {
            let reason = json::field_str(wakes, "reason").filter(|text| !text.is_empty());
            // BEFORE THE FIRST TICK IS NOT A RED: wakes_not_reported_yet is what a node answers between its start
            // and its first placement tick, which is exactly when an install judges it.
            if reason.as_deref() == Some("wakes_not_reported_yet") {
                return Wakes::Waiting(
                    "no tick has published wake facts since this node started (wakes_not_reported_yet)".to_string(),
                );
            }
            let why = json::field_str(wakes, "error")
                .filter(|text| !text.is_empty())
                .map(|error| format!(" ({error})"))
                .unwrap_or_default();
            return Wakes::Red(vec![format!(
                "RED wakes_unknown: {}{why}",
                reason.unwrap_or_else(|| "no reason given".to_string())
            )]);
        }
        None => return Wakes::Red(vec!["RED wakes_unknown: known is missing from /health.wakes".to_string()]),
    }
    let tick = match json::field(wakes, "last_tick") {
        Some(value) if value.trim_start().starts_with('{') => value.to_string(),
        _ => return Wakes::Red(vec!["RED wakes_unknown: last_tick is missing from /health.wakes".to_string()]),
    };
    let outcome = json::field_str(&tick, "outcome").unwrap_or_default();
    let mut reds = Vec::new();
    match outcome.as_str() {
        "ok" => {}
        "selfloop_tick_failed" => {
            let error = json::field_str(&tick, "error").filter(|text| !text.is_empty());
            reds.push(format!(
                "RED selfloop_tick_failed: {}",
                error.unwrap_or_else(|| "no error recorded".to_string())
            ));
        }
        "" => return Wakes::Red(vec!["RED wakes_unknown: last_tick.outcome is missing".to_string()]),
        other => return Wakes::Red(vec![format!("RED wakes_unknown: last_tick outcome {other}")]),
    }
    let ticks = match json::field_u64(wakes, "ticks_since_start") {
        Some(value) => value,
        None => return missing("ticks_since_start"),
    };
    let ticking = match json::field_u64(wakes, "ticking_for_s") {
        Some(value) => value,
        None => return missing("ticking_for_s"),
    };
    let published = match json::field_u64(wakes, "published_age_ms") {
        Some(value) => value,
        None => return missing("published_age_ms"),
    };
    let dispatchable = match json::field_u64(wakes, "dispatchable") {
        Some(value) => value,
        None => return missing("dispatchable"),
    };
    let oldest = match json::field_u64(wakes, "oldest_dispatchable_age_s") {
        Some(value) => value,
        None => return missing("oldest_dispatchable_age_s"),
    };
    let held = json::field_u64(wakes, "deploy_waiting").unwrap_or(0);
    if ticks == 0 {
        return Wakes::Waiting("the node published a tick count of 0 (no tick since it started)".to_string());
    }
    // THE NAMES `node_state.state` CAN TAKE (rust/wa-capabilities/src/serve.rs): idle, busy, upgrading. A name this
    // rule does not know is a red, so a new state cannot silently switch the checks off.
    let lane = json::field(body, "node_state")
        .map(|state| json::field_str(state, "state").unwrap_or_default())
        .unwrap_or_default();
    if lane.is_empty() {
        return Wakes::Red(vec!["RED wakes_unknown: node_state.state is missing from /health".to_string()]);
    }
    if !["idle", "busy", "upgrading"].contains(&lane.as_str()) {
        return Wakes::Red(vec![format!(
            "RED wakes_unknown: node_state.state \"{lane}\" is not a name this rule knows (idle, busy, upgrading)"
        )]);
    }
    let worker = json::field_str(body, "worker").unwrap_or_default();
    if worker.is_empty() {
        return Wakes::Red(vec!["RED wakes_unknown: worker is missing from /health".to_string()]);
    }
    if published > WAKE_PUBLISH_SECONDS * 1000 {
        reds.push(format!(
            "RED wakes_not_publishing: {published} ms old (bound {WAKE_PUBLISH_SECONDS}s)"
        ));
    }
    // THE ROW'S AGE COUNTS FROM THIS PROCESS'S FIRST TICK, AND WHAT THE NODE IS DELIBERATELY HOLDING IS NOT A
    // STALL: a row that came due during an install is not older than the process that should have dispatched it,
    // and the rows a deploy holds (`deploy_waiting`) are held on purpose. "No turn is running" is by name: busy is
    // a turn, but busy with a STALLED worker is a wedged lane - and a wedged lane must not hide a dead loop.
    let not_held = dispatchable.saturating_sub(held);
    let age = oldest.min(ticking);
    let no_turn = lane != "busy" || worker == "stalled";
    if not_held > 0 && age > WAKE_STALL_SECONDS && no_turn {
        reds.push(format!(
            "RED self_wake_stalled: {not_held} due row(s) the node is not holding, oldest {age}s (counted from this process, {ticking}s), lane {lane}"
        ));
    }
    if reds.is_empty() {
        Wakes::Green(format!(
            "GREEN wakes: last_tick ok, {dispatchable} dispatchable ({held} held for a deploy), oldest {oldest}s, ticking {ticking}s, lane {lane}, worker {worker}"
        ))
    } else {
        Wakes::Red(reds)
    }
}

#[derive(Debug, Clone, Default)]
pub struct Probe {
    /// A response arrived (a socket that accepts and says nothing is `answered: false`).
    pub answered: bool,
    /// The HTTP status code, when a status line could be read.
    pub status: u16,
    /// The response body as text (lossy UTF-8: a probe must never fail on bytes).
    pub body: String,
    /// `/health`'s top-level `ok`, when it is a boolean.
    pub ok: Option<bool>,
    /// `/health`'s top-level `state` (`alive`/`busy`/`stalled`/`idle`/`upgrading`), when present.
    pub state: Option<String>,
    /// Why this probe did not get an answer, in one line. Never message text: this is a socket error, a
    /// timeout, or a malformed status line.
    pub detail: Option<String>,
    /// The node's own self-wake loop, judged by [`wake_verdict`]. Reported, never part of [`Probe::ready`].
    pub wakes: Wakes,
}

impl Probe {
    /// Something answered with a 200. Says nothing about health.
    pub fn answers(&self) -> bool {
        self.answered && self.status == 200
    }

    /// The one question the supervisor asks before it declares a kernel up: does it answer, and does its
    /// own report say `ok: true`.
    pub fn ready(&self) -> bool {
        self.answers() && self.ok == Some(true)
    }

    /// A one-line reason, for a log line or a swap refusal. Contains no body text.
    pub fn why_not(&self) -> String {
        if let Some(detail) = &self.detail {
            return detail.clone();
        }
        if !self.answered {
            return "no answer".to_string();
        }
        if self.status != 200 {
            return format!("status {}", self.status);
        }
        match self.ok {
            Some(true) => "ready".to_string(),
            Some(false) => format!("ok:false (state {})", self.state.clone().unwrap_or_else(|| "unknown".into())),
            None => "no top-level \"ok\" in /health".to_string(),
        }
    }
}

/// GET `/health` on `127.0.0.1:port`. `timeout` bounds the connect and each read, so the whole call is
/// bounded by a small multiple of it.
pub fn probe(port: u16, timeout: Duration) -> Probe {
    let deadline = Instant::now() + timeout;
    let address = match ("127.0.0.1", port).to_socket_addrs().ok().and_then(|mut addrs| addrs.next()) {
        Some(address) => address,
        None => {
            return Probe {
                detail: Some(format!("no address for 127.0.0.1:{port}")),
                ..Default::default()
            }
        }
    };
    let mut stream = match TcpStream::connect_timeout(&address, timeout) {
        Ok(stream) => stream,
        Err(error) => {
            return Probe { detail: Some(format!("connect: {}", short(&error))), ..Default::default() };
        }
    };
    let remaining = || deadline.saturating_duration_since(Instant::now()).max(Duration::from_millis(1));
    let _ = stream.set_read_timeout(Some(remaining()));
    let _ = stream.set_write_timeout(Some(remaining()));
    let request =
        format!("GET /health HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAccept: application/json\r\nConnection: close\r\n\r\n");
    if let Err(error) = stream.write_all(request.as_bytes()) {
        return Probe { detail: Some(format!("write: {}", short(&error))), ..Default::default() };
    }
    let mut raw = Vec::new();
    let mut buf = [0u8; 8192];
    loop {
        let _ = stream.set_read_timeout(Some(remaining()));
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(read) => {
                raw.extend_from_slice(&buf[..read]);
                if raw.len() > MAX_BODY + 8192 {
                    break;
                }
                // Keep the whole response (head and body): `parse_response` needs the status line. This only
                // asks "has the body promised by Content-Length arrived yet", so the socket is not read past
                // the end of a keep-alive response.
                if complete_body(&raw).is_some() {
                    break;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => {
                if raw.is_empty() {
                    return Probe { detail: Some(format!("read: {}", short(&error))), ..Default::default() };
                }
                // A partial response that a short timeout cut off is still an answer: parse what arrived
                // rather than reporting the peer as silent.
                break;
            }
        }
    }
    parse_response(&raw)
}

fn short(error: &std::io::Error) -> String {
    // `Display` for an OS error carries the OS message; keep it on one line and bounded.
    let text = error.to_string().replace(['\r', '\n'], " ");
    text.chars().take(120).collect()
}

/// The body of a response whose `Content-Length` is fully buffered, or `None` while more bytes are needed.
fn complete_body(raw: &[u8]) -> Option<Vec<u8>> {
    let (header_end, body_start) = header_bounds(raw)?;
    let headers = String::from_utf8_lossy(&raw[..header_end]).to_string();
    let length = header_value(&headers, "content-length")?.parse::<usize>().ok()?;
    if raw.len() >= body_start + length {
        Some(raw[body_start..body_start + length].to_vec())
    } else {
        None
    }
}

/// `(index of the end of the headers, index of the first body byte)`.
fn header_bounds(raw: &[u8]) -> Option<(usize, usize)> {
    if let Some(index) = raw.windows(4).position(|window| window == b"\r\n\r\n") {
        return Some((index, index + 4));
    }
    raw.windows(2).position(|window| window == b"\n\n").map(|index| (index, index + 2))
}

fn header_value(headers: &str, name: &str) -> Option<String> {
    for line in headers.lines().skip(1) {
        let (key, value) = line.split_once(':')?;
        if key.trim().eq_ignore_ascii_case(name) {
            return Some(value.trim().to_string());
        }
    }
    None
}

fn parse_response(raw: &[u8]) -> Probe {
    let (header_end, body_start) = match header_bounds(raw) {
        Some(bounds) => bounds,
        None => {
            return Probe { detail: Some("no header terminator".to_string()), ..Default::default() }
        }
    };
    let headers = String::from_utf8_lossy(&raw[..header_end]).to_string();
    let status = headers
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse::<u16>().ok());
    let status = match status {
        Some(status) => status,
        None => return Probe { detail: Some("no status line".to_string()), ..Default::default() },
    };
    let body_bytes = &raw[body_start..];
    let body = if header_value(&headers, "transfer-encoding").is_some_and(|value| value.to_ascii_lowercase().contains("chunked")) {
        decode_chunked(body_bytes)
    } else {
        body_bytes.to_vec()
    };
    let body = String::from_utf8_lossy(&body).to_string();
    Probe {
        answered: true,
        status,
        ok: json::field_bool(&body, "ok"),
        state: json::field_str(&body, "state"),
        wakes: wake_verdict(&body),
        body,
        detail: None,
    }
}

/// A minimal chunked decoder. Returns what it could decode: a truncated tail (a timeout mid-stream) is not
/// a reason to call a healthy node silent.
fn decode_chunked(raw: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut index = 0usize;
    while let Some(offset) = raw[index..].windows(2).position(|window| window == b"\r\n") {
        let line_end = index + offset;
        let size_text = String::from_utf8_lossy(&raw[index..line_end]).to_string();
        let size_text = size_text.split(';').next().unwrap_or("").trim().to_string();
        let size = match usize::from_str_radix(&size_text, 16) {
            Ok(size) => size,
            Err(_) => break,
        };
        index = line_end + 2;
        if size == 0 {
            break;
        }
        let end = std::cmp::min(index + size, raw.len());
        out.extend_from_slice(&raw[index..end]);
        index = end;
        // The chunk is followed by CRLF; a truncated tail simply ends the decode.
        let crlf = raw.get(index) == Some(&b'\r') && raw.get(index + 1) == Some(&b'\n');
        let bare_lf = raw.get(index) == Some(&b'\n');
        if crlf {
            index += 2;
        } else if bare_lf {
            index += 1;
        } else {
            break;
        }
        if index >= raw.len() {
            break;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    /// A one-shot HTTP server on a port of its own. Returns the port.
    fn server(response: &'static [u8]) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind a probe test port");
        let port = listener.local_addr().expect("local addr").port();
        thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let _ = stream.write_all(response);
            }
        });
        port
    }

    #[test]
    fn a_ready_node_is_ready() {
        let port = server(
            b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{\"ok\":true,\"state\":\"idle\"}",
        );
        // The length above is deliberately the real one for that body.
        let probe = probe(port, Duration::from_millis(1500));
        assert!(probe.answers(), "answered: {probe:?}");
        assert_eq!(probe.ok, Some(true));
        assert_eq!(probe.state.as_deref(), Some("idle"));
        assert!(probe.ready());
    }

    #[test]
    fn a_node_that_answers_ok_false_is_answering_and_not_ready() {
        let body = "{\"ok\":false,\"state\":\"stalled\"}";
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
        let leaked: &'static [u8] = Box::leak(response.into_bytes().into_boxed_slice());
        let probe = probe(server(leaked), Duration::from_millis(1500));
        assert!(probe.answers());
        assert!(!probe.ready());
        assert_eq!(probe.why_not(), "ok:false (state stalled)");
    }

    #[test]
    fn a_body_without_content_length_is_read_to_eof() {
        let leaked: &'static [u8] = b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{\"ok\":true}";
        let probe = probe(server(leaked), Duration::from_millis(1500));
        assert!(probe.ready(), "{probe:?}");
    }

    #[test]
    fn a_chunked_body_is_decoded() {
        // {"ok":true} split into two chunks.
        let leaked: &'static [u8] =
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n8\r\n{\"ok\":tr\r\n3\r\nue}\r\n0\r\n\r\n";
        let probe = probe(server(leaked), Duration::from_millis(1500));
        assert!(probe.ready(), "{probe:?}");
        assert_eq!(probe.body, "{\"ok\":true}");
    }

    #[test]
    fn a_refused_port_is_not_answered() {
        // Bind and drop: the port is (almost certainly) free, so nothing listens on it.
        let port = {
            let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
            listener.local_addr().expect("addr").port()
        };
        let probe = probe(port, Duration::from_millis(200));
        assert!(!probe.answered);
        assert!(!probe.ready());
        assert!(!probe.why_not().contains("ready"), "the refusal names a cause: {}", probe.why_not());
    }

    #[test]
    fn a_socket_that_says_nothing_is_bounded_by_the_timeout() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("addr").port();
        // Accept the connection and never answer.
        thread::spawn(move || {
            let _held = listener.accept();
            thread::sleep(Duration::from_millis(1500));
        });
        let started = Instant::now();
        let probe = probe(port, Duration::from_millis(300));
        assert!(!probe.answered);
        assert!(started.elapsed() < Duration::from_millis(1200), "probe returned in {:?}", started.elapsed());
    }

    // ---- the self-wake rule (r8c item G) ---------------------------------------------------------------
    //
    // The bodies are the SHAPE A REAL NODE ANSWERS: the healthy and broken ones are captures of
    // scripts/test-health-wakes-rule.cjs's scratch node (this laptop, 24/11 - a wake dispatched, then a column
    // the tick reads dropped), with the fields this rule does not read removed. The same bodies are judged by
    // scripts/lib/health-wakes.sh in that row, so the two implementations cannot drift apart in silence.
    // The shape a real node answers AFTER the change: `ticks_since_start`, `ticking_for_s`, `oldest_dispatchable_age_s`
    // (0 when nothing is due), `deploy_waiting`, and /health's `worker` beside `node_state`.
    const GREEN: &str = r#"{"ok":true,"worker":"alive","wakes":{"dispatchable":0,"due":0,"held_due":0,"known":true,"deploy_waiting":0,"first_tick_at":1795547600,"ticks_since_start":42,"ticking_for_s":84,"last_dispatch_at":1795547610.602,"last_tick":{"at":1795547610,"error":"","outcome":"ok"},"now":1795547610.6194,"oldest_dispatchable_age_s":0,"published_age_ms":386},"node_state":{"busy_threads":0,"queue":0,"state":"idle"}}"#;
    const RAISED: &str = r#"{"ok":true,"worker":"alive","wakes":{"dispatchable":1,"due":1,"held_due":0,"known":true,"deploy_waiting":0,"first_tick_at":1795547616,"ticks_since_start":3,"ticking_for_s":4,"last_dispatch_at":1795547610.9721,"last_tick":{"at":1795547620,"error":"no such column: boot","outcome":"selfloop_tick_failed"},"now":1795547620.955,"oldest_dispatchable_age_s":4,"published_age_ms":1907},"node_state":{"busy_threads":0,"queue":0,"state":"idle"}}"#;

    #[test]
    fn a_healthy_loop_is_green() {
        assert_eq!(
            wake_verdict(GREEN).lines(),
            vec!["GREEN wakes: last_tick ok, 0 dispatchable (0 held for a deploy), oldest 0s, ticking 84s, lane idle, worker alive"]
        );
    }

    #[test]
    fn before_the_first_tick_is_waiting_not_a_red_and_not_green() {
        // EXACTLY WHAT AN INSTALL SEES. serve.rs answers this shape between the node's start and its first tick, and
        // the shell reader waits for the tick instead of failing a good install (scripts/lib/health-wakes.sh).
        let waiting = r#"{"ok":true,"worker":"alive","wakes":{"known":false,"reason":"wakes_not_reported_yet","note":"no placement tick has published wake facts since this node started"},"node_state":{"state":"idle"}}"#;
        let verdict = wake_verdict(waiting);
        assert_eq!(
            verdict.lines(),
            vec!["WAITING wakes: no tick has published wake facts since this node started (wakes_not_reported_yet)"]
        );
        assert!(!verdict.is_green(), "waiting is not a pass");
        assert!(!verdict.lines()[0].starts_with("RED"), "waiting is not a red");
        // A tick count of 0 is the same state, named the other way.
        let zero = GREEN.replace(r#""ticks_since_start":42"#, r#""ticks_since_start":0"#);
        assert_eq!(wake_verdict(&zero).lines(), vec!["WAITING wakes: the node published a tick count of 0 (no tick since it started)"]);
    }

    #[test]
    fn a_missing_field_is_red_by_name_never_a_skipped_check() {
        for (field, body) in [
            ("published_age_ms", GREEN.replace(r#","published_age_ms":386"#, "")),
            ("dispatchable", GREEN.replace(r#""dispatchable":0,"#, "")),
            ("oldest_dispatchable_age_s", GREEN.replace(r#","oldest_dispatchable_age_s":0"#, "")),
        ] {
            assert_eq!(
                wake_verdict(&body).lines(),
                vec![format!("RED wakes_unknown: {field} is missing from /health.wakes")],
                "a body without {field} must be red, by name"
            );
        }
        let no_lane = GREEN.replace(r#","node_state":{"busy_threads":0,"queue":0,"state":"idle"}"#, "");
        assert_eq!(
            wake_verdict(&no_lane).lines(),
            vec!["RED wakes_unknown: node_state.state is missing from /health"]
        );
        // AND A STATE NAME THIS RULE DOES NOT KNOW IS A RED, not a way to switch the checks off.
        let stranger = GREEN.replace(r#""state":"idle""#, r#""state":"prewarming""#);
        assert_eq!(
            wake_verdict(&stranger).lines(),
            vec!["RED wakes_unknown: node_state.state \"prewarming\" is not a name this rule knows (idle, busy, upgrading)"]
        );
    }

    #[test]
    fn a_raised_tick_is_red_by_name_with_the_error_it_raised() {
        let verdict = wake_verdict(RAISED);
        assert_eq!(verdict.lines(), vec!["RED selfloop_tick_failed: no such column: boot"]);
        assert!(!verdict.is_green());
    }

    #[test]
    fn a_due_row_past_the_bound_with_no_turn_running_is_red_and_a_running_turn_is_not() {
        // The same row and the same age, once with no turn running (the loop is not dispatching what it owes) and
        // once with a turn running (a wake turn is in flight: nothing is stalled).
        let idle = RAISED
            .replace(r#""oldest_dispatchable_age_s":4"#, r#""oldest_dispatchable_age_s":200"#)
            .replace(r#""ticking_for_s":4"#, r#""ticking_for_s":400"#)
            .replace(r#""outcome":"selfloop_tick_failed""#, r#""outcome":"ok""#)
            .replace(r#""error":"no such column: boot""#, r#""error":"""#);
        assert_eq!(
            wake_verdict(&idle).lines(),
            vec!["RED self_wake_stalled: 1 due row(s) the node is not holding, oldest 200s (counted from this process, 400s), lane idle"]
        );
        let busy = idle.replace(r#""state":"idle""#, r#""state":"busy""#);
        assert_eq!(
            wake_verdict(&busy).lines(),
            vec!["GREEN wakes: last_tick ok, 1 dispatchable (0 held for a deploy), oldest 200s, ticking 400s, lane busy, worker alive"]
        );
        // A WEDGED LANE IS NOT A RUNNING TURN: busy with a stalled worker must still name the stall.
        let wedged = busy.replace(r#""worker":"alive""#, r#""worker":"stalled""#);
        assert_eq!(
            wake_verdict(&wedged).lines(),
            vec!["RED self_wake_stalled: 1 due row(s) the node is not holding, oldest 200s (counted from this process, 400s), lane busy"]
        );
        // AND A ROW THE NODE IS DELIBERATELY HOLDING FOR A DEPLOY IS NOT A STALL (a landing node).
        let held = idle.replace(r#""deploy_waiting":0"#, r#""deploy_waiting":1"#);
        assert_eq!(
            wake_verdict(&held).lines(),
            vec!["GREEN wakes: last_tick ok, 1 dispatchable (1 held for a deploy), oldest 200s, ticking 400s, lane idle, worker alive"]
        );
    }

    #[test]
    fn the_age_counts_from_this_process_s_first_tick() {
        // THE GOOD INSTALL THAT WOULD HAVE FAILED: a row that came due ten minutes ago, on a process that has been
        // ticking for three seconds. Its own date is not the node's debt - the process that should dispatch it was
        // not running - so this is not a stall until the process itself has had the bound.
        let cold = RAISED
            .replace(r#""oldest_dispatchable_age_s":4"#, r#""oldest_dispatchable_age_s":600"#)
            .replace(r#""ticking_for_s":4"#, r#""ticking_for_s":3"#)
            .replace(r#""ticks_since_start":3"#, r#""ticks_since_start":1"#)
            .replace(r#""outcome":"selfloop_tick_failed""#, r#""outcome":"ok""#)
            .replace(r#""error":"no such column: boot""#, r#""error":"""#);
        assert_eq!(
            wake_verdict(&cold).lines(),
            vec!["GREEN wakes: last_tick ok, 1 dispatchable (0 held for a deploy), oldest 600s, ticking 3s, lane idle, worker alive"]
        );
        let late = cold.replace(r#""ticking_for_s":3"#, r#""ticking_for_s":300"#);
        assert_eq!(
            wake_verdict(&late).lines(),
            vec!["RED self_wake_stalled: 1 due row(s) the node is not holding, oldest 300s (counted from this process, 300s), lane idle"]
        );
    }

    #[test]
    fn a_publisher_that_stopped_is_red() {
        let stale = GREEN.replace(r#""published_age_ms":386"#, r#""published_age_ms":41000"#);
        assert_eq!(wake_verdict(&stale).lines(), vec!["RED wakes_not_publishing: 41000 ms old (bound 30s)"]);
    }

    #[test]
    fn a_node_that_cannot_say_what_its_wake_state_is_is_unknown_never_green() {
        // No wakes field at all: a node older than this rule. The verdict names that, and it is not green.
        let older = r#"{"ok":true,"node_state":{"state":"idle"}}"#;
        assert_eq!(
            wake_verdict(older).lines(),
            vec!["UNKNOWN wakes: /health has no wakes object (a node older than this rule, or a body that is not one)"]
        );
        // The node's own refusal, with its reason, is a red by name.
        let failed = r#"{"ok":true,"wakes":{"known":false,"reason":"wake_facts_failed"}}"#;
        assert_eq!(wake_verdict(failed).lines(), vec!["RED wakes_unknown: wake_facts_failed"]);
        // An outcome the node cannot vouch for is not "ok" either.
        let unset = r#"{"ok":true,"wakes":{"known":true,"last_tick":{"at":0,"outcome":"unknown"}}}"#;
        assert_eq!(wake_verdict(unset).lines(), vec!["RED wakes_unknown: last_tick outcome unknown"]);
    }

    #[test]
    fn a_wake_red_is_reported_and_never_makes_a_node_unready() {
        // THE LINE THIS FILE MUST NOT CROSS: `ready()` decides a kernel is up and a swap committed. A node
        // whose loop is dead answered ok:true on 24/11 for 2.5 hours, and restarting it under a running turn -
        // or rolling back an install for a wake it owes itself - would be worse than reporting it.
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("addr").port();
        let body = RAISED.as_bytes().to_vec();
        thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let _ = stream.write_all(
                    format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", body.len()).as_bytes(),
                );
                let _ = stream.write_all(&body);
            }
        });
        let probe = probe(port, Duration::from_millis(2_000));
        assert!(probe.answered, "the probe answered: {:?}", probe.detail);
        assert!(probe.ready(), "ok:true is what `ready` asks, and a wake red does not change it");
        assert!(!probe.wakes.is_green(), "and the wake verdict is still a red");
        assert_eq!(probe.wakes.lines(), vec!["RED selfloop_tick_failed: no such column: boot"]);
    }
}

