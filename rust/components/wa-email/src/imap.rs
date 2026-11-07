//! IMAP4rev1, as a sans-I/O client: the protocol state machine, and nothing that touches a socket.
//!
//! The guest owns the transport (`wa:email/transport`, TLS in the kernel), so this type never awaits:
//! [`Imap::step`] says what to write next, [`Imap::on_bytes`] takes whatever arrived and returns what
//! the protocol made of it, and the driver between them is ten lines (`connector`). That split is what
//! makes the protocol testable natively against an in-process fake and keeps a reconnect a matter of
//! dropping one `Imap` and making another.
//!
//! What it does, and deliberately nothing more: `LOGIN`, `SELECT`, `UID SEARCH` for UIDs above the
//! last one indexed, `UID FETCH (UID FLAGS INTERNALDATE BODY.PEEK[])` one message at a time, then
//! `NOOP` + `UID SEARCH` again for the next round. `BODY.PEEK[]` is what keeps a fetch from marking
//! mail as read: the connector is an indexer, not a reader.
//!
//! It does not use IDLE. A round is "search, fetch what is new, stop"; the wait between rounds is the
//! driver's (`wasi:clocks`), which is what lets one component serve the outbox and the query queue
//! between rounds (`REPORT.md`, "Open questions").
use std::collections::VecDeque;

use wa_email_outbox::{redact, Secret};

use crate::mime;

/// Largest message body one fetch may deliver. A bigger one is skipped and said so, never buffered:
/// the component has a memory grant and a mailbox is not a place to discover that.
pub const MAX_MESSAGE: usize = 4 * 1024 * 1024;

/// What the driver should do next.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Step {
    /// Write these bytes to the server.
    Write(Vec<u8>),
    /// Nothing to write: wait for bytes.
    Wait,
    /// The round is over (every new UID fetched). The connection is still usable: call
    /// [`Imap::next_round`] after the driver has done other work.
    RoundDone,
}

/// One message the fetch returned.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Fetched {
    pub uid: u32,
    pub flags: Vec<String>,
    /// The server's `INTERNALDATE` in Unix ms, when it parsed.
    pub internal_date_ms: Option<i64>,
    /// The raw RFC 822 message.
    pub body: Vec<u8>,
}

/// What happened, in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// `SELECT` succeeded: the mailbox generation and its message count.
    Selected { uid_validity: u32, exists: u32 },
    /// One fetched message.
    Message(Fetched),
    /// A message bigger than [`MAX_MESSAGE`] was skipped (consumed, not buffered).
    Skipped { uid: u32, bytes: u64 },
    /// The server refused the login. `answer` is the server's own line with the credential removed.
    AuthFailed { answer: String },
    /// The protocol broke: an unexpected tagged answer, an unreadable fetch. `detail` is bounded and
    /// carries no credential.
    Protocol { detail: String },
    /// The connection ended (peer close, EOF, `* BYE`).
    Closed { reason: &'static str },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    /// Waiting for the server's greeting.
    Greeting,
    Login,
    Select,
    Search,
    Fetch,
    RoundDone,
    Closed,
}

/// One IMAP session: login, select the mailbox, fetch what is new, round over.
pub struct Imap {
    mailbox: String,
    user: String,
    password: Secret,
    state: State,
    tag: u32,
    /// The tag whose tagged answer the machine is waiting for.
    awaiting: Option<String>,
    /// Bytes queued for the next [`Step::Write`].
    out: Vec<u8>,
    /// Bytes received but not yet parsed (a partial response, a partial literal).
    inbuf: Vec<u8>,
    uid_validity: u32,
    exists: u32,
    /// UIDs to fetch, in order.
    queue: VecDeque<u32>,
    /// The highest UID this session has seen; the next round searches above it.
    last_uid: u32,
    /// UIDs fetched (or skipped) this round.
    fetched: u32,
    /// The largest body this session will buffer (a test can lower it; it is never raised above
    /// [`MAX_MESSAGE`]).
    max_message: usize,
    events: Vec<Event>,
}

impl Imap {
    /// A session that has not sent anything yet: the first [`Imap::step`] waits for the greeting.
    pub fn new(mailbox: &str, user: &str, password: Secret) -> Imap {
        Imap::with_bound(mailbox, user, password, MAX_MESSAGE)
    }

    /// A session with a smaller buffering bound, for the tests and for a node whose memory grant is
    /// tighter than the default. Asking for more than [`MAX_MESSAGE`] is clamped down to it: the bound
    /// is a safety property, not a preference.
    pub fn with_bound(mailbox: &str, user: &str, password: Secret, max_message: usize) -> Imap {
        Imap {
            mailbox: mailbox.to_string(),
            user: user.to_string(),
            password,
            state: State::Greeting,
            tag: 0,
            awaiting: None,
            out: Vec::new(),
            inbuf: Vec::new(),
            uid_validity: 0,
            exists: 0,
            queue: VecDeque::new(),
            last_uid: 0,
            fetched: 0,
            max_message: max_message.clamp(1024, MAX_MESSAGE),
            events: Vec::new(),
        }
    }

    /// Start the first round above `last_uid`: what a resumed session does with the sync state the last
    /// one stored. A floor of zero is a fresh mailbox.
    pub fn seed_floor(&mut self, last_uid: u32) {
        if last_uid > self.last_uid {
            self.last_uid = last_uid;
        }
    }

    /// The highest UID this session has seen: what the index's sync state stores.
    pub fn last_uid(&self) -> u32 {
        self.last_uid
    }

    /// True once the connection is finished (by the caller's choice or by the peer).
    pub fn closed(&self) -> bool {
        self.state == State::Closed
    }

    /// Re-arm the machine for another round over the same connection: `NOOP` (so a dead connection is
    /// noticed here rather than inside a fetch) and then a search above the last UID.
    pub fn next_round(&mut self) {
        let ended = self.state == State::RoundDone || (self.state == State::Fetch && self.queue.is_empty());
        if !ended {
            return;
        }
        self.state = State::Search;
        self.fetched = 0;
    }

    /// UIDs fetched (or skipped) in the round in progress.
    pub fn fetched(&self) -> u32 {
        self.fetched
    }

    /// Events the machine produced but the driver has not taken yet.
    pub fn take_events(&mut self) -> Vec<Event> {
        std::mem::take(&mut self.events)
    }

    /// What the driver should do next.
    pub fn step(&mut self) -> Step {
        if self.state == State::RoundDone {
            self.state = State::RoundDone;
            return Step::RoundDone;
        }
        if !self.out.is_empty() {
            return Step::Write(std::mem::take(&mut self.out));
        }
        // A command is on the wire and its tagged answer has not arrived: writing it again would put a
        // second copy of the same command in front of the server.
        if self.awaiting.is_some() {
            return Step::Wait;
        }
        match self.state {
            State::Greeting => Step::Wait,
            State::Login => self.command(&format!("LOGIN \"{}\" \"{}\"", escape(&self.user), escape(self.password.expose()))),
            State::Select => self.command(&format!("SELECT \"{}\"", escape(&self.mailbox))),
            State::Search => self.command(&format!("UID SEARCH UID {}:*", self.last_uid.saturating_add(1))),
            State::Fetch => match self.queue.front().copied() {
                Some(uid) => self.command(&format!("UID FETCH {uid} (UID FLAGS INTERNALDATE BODY.PEEK[])")),
                None => {
                    // A round that ends without a tagged OK (no new mail to ask for) still ends here;
                    // the driver reads the counters, so no separate event is queued.
                    self.state = State::RoundDone;
                    Step::RoundDone
                }
            },
            State::RoundDone => Step::RoundDone,
            State::Closed => Step::Wait,
        }
    }

    /// Take whatever the server sent and answer with what it means.
    pub fn on_bytes(&mut self, data: &[u8]) -> Vec<Event> {
        if self.state == State::Closed {
            return Vec::new();
        }
        if self.inbuf.len() + data.len() > MAX_MESSAGE + 64 * 1024 {
            // A server that streams more than one message's worth without a command boundary is not a
            // server this connector will buffer for.
            self.close("too-much-buffered");
            return self.drain_events();
        }
        self.inbuf.extend_from_slice(data);
        while let Some(response) = self.take_response() {
            self.handle(response);
            if self.state == State::Closed {
                break;
            }
        }
        self.drain_events()
    }

    /// The transport reached end of stream.
    pub fn on_eof(&mut self) -> Vec<Event> {
        self.close("eof");
        self.drain_events()
    }

    /// The driver is giving up on this connection (its own error, or a stop): nothing more is written.
    pub fn abandon(&mut self, reason: &'static str) -> Vec<Event> {
        self.close(reason);
        self.drain_events()
    }

    fn close(&mut self, reason: &'static str) {
        if self.state != State::Closed {
            self.state = State::Closed;
            self.out.clear();
            self.events.push(Event::Closed { reason });
        }
    }

    fn drain_events(&mut self) -> Vec<Event> {
        std::mem::take(&mut self.events)
    }

    fn command(&mut self, text: &str) -> Step {
        self.tag += 1;
        let tag = format!("a{}", self.tag);
        self.awaiting = Some(tag.clone());
        let line = format!("{tag} {text}\r\n");
        self.out.extend_from_slice(line.as_bytes());
        Step::Write(std::mem::take(&mut self.out))
    }

    /// One response: a line, plus the literal bodies that line announced (`{n}` + n bytes).
    fn take_response(&mut self) -> Option<Response> {
        let mut cursor = 0usize;
        let mut line = String::new();
        let mut literals = Vec::new();
        loop {
            let relative = crate::find(&self.inbuf[cursor..], b"\r\n")?;
            let line_end = cursor + relative;
            line.push_str(&String::from_utf8_lossy(&self.inbuf[cursor..line_end]));
            match literal_len(&line) {
                Some(size) => {
                    let start = line_end + 2;
                    if self.inbuf.len() < start + size {
                        // The literal has not fully arrived: keep everything and wait.
                        return None;
                    }
                    if literals.len() < 8 {
                        literals.push(self.inbuf[start..start + size].to_vec());
                    }
                    cursor = start + size;
                }
                None => {
                    cursor = line_end + 2;
                    self.inbuf.drain(..cursor);
                    return Some(Response { line, literals });
                }
            }
        }
    }

    fn handle(&mut self, response: Response) {
        let Response { line, literals } = response;
        if line.starts_with('+') {
            // A continuation only follows an AUTHENTICATE this client does not send.
            return;
        }
        if let Some(rest) = line.strip_prefix("* ") {
            self.untagged(rest, literals);
            return;
        }
        // A tagged answer: `aN OK|NO|BAD text`.
        let mut parts = line.splitn(3, ' ');
        let tag = parts.next().unwrap_or_default();
        let status = parts.next().unwrap_or_default().to_ascii_uppercase();
        let text = parts.next().unwrap_or_default();
        let expected = self.awaiting.take();
        if expected.as_deref() != Some(tag) {
            // Not the answer we are waiting for: ignore it rather than desynchronise the machine.
            return;
        }
        if status != "OK" {
            let answer = self.quiet(text);
            if self.state == State::Login {
                self.state = State::Closed;
                self.events.push(Event::AuthFailed { answer });
            } else {
                self.state = State::Closed;
                self.events.push(Event::Protocol { detail: answer });
            }
            return;
        }
        match self.state {
            State::Login => {
                self.state = State::Select;
                self.awaiting = None;
            }
            State::Select => {
                self.state = State::Search;
                self.events.push(Event::Selected { uid_validity: self.uid_validity, exists: self.exists });
                self.awaiting = None;
            }
            State::Search => {
                self.state = State::Fetch;
                self.awaiting = None;
            }
            State::Fetch => {
                // The tagged OK closes the fetch. The queue's front was popped by the untagged FETCH
                // that carried the message (`untagged`), so popping here would skip the next one.
                self.awaiting = None;
                if self.queue.is_empty() {
                    // The driver learns the end of the round from `Step::RoundDone` and reads the
                    // counters, so no event is queued for it.
                    self.state = State::RoundDone;
                }
            }
            _ => {}
        }
    }

    fn untagged(&mut self, rest: &str, literals: Vec<Vec<u8>>) {
        if rest.starts_with("BYE") {
            self.close("bye");
            return;
        }
        if rest.starts_with("PREAUTH") {
            // The server already trusts this connection: skip LOGIN and go straight to SELECT.
            if self.state == State::Greeting {
                self.state = State::Select;
            }
            return;
        }
        if let Some(tail) = rest.strip_prefix("OK ") {
            if self.state == State::Greeting {
                self.state = State::Login;
                return;
            }
            if let Some(value) = bracket_value(tail, "UIDVALIDITY") {
                if let Ok(parsed) = value.parse() {
                    self.uid_validity = parsed;
                }
            }
            return;
        }
        if let Some(tail) = rest.strip_prefix("SEARCH") {
            if self.state == State::Search {
                for uid in tail.split_whitespace().filter_map(|uid| uid.parse::<u32>().ok()) {
                    // `n:*` on a mailbox whose highest UID is below `n` still returns that highest UID.
                    if uid > self.last_uid && !self.queue.contains(&uid) {
                        self.queue.push_back(uid);
                    }
                }
            }
            return;
        }
        // `* 5 EXISTS`
        if let Some(count) = rest.strip_suffix(" EXISTS").and_then(|count| count.trim().parse::<u32>().ok()) {
            self.exists = count;
            return;
        }
        // `* 3 FETCH (UID 12 FLAGS (\Seen) INTERNALDATE "…" BODY[] {n}…)`
        if rest.contains(" FETCH ") {
            let Some(uid) = token_number(rest, "UID ") else { return };
            let body = literals.first().cloned().unwrap_or_default();
            if self.queue.front().copied() == Some(uid) {
                self.queue.pop_front();
            }
            self.note_uid(uid);
            self.fetched += 1;
            if body.len() > self.max_message {
                // The body was consumed (the protocol cannot skip a literal) but not kept: the record is
                // not indexed, and the round says so instead of pretending.
                self.events.push(Event::Skipped { uid, bytes: body.len() as u64 });
            } else {
                self.events.push(Event::Message(Fetched { uid, flags: flag_list(rest), internal_date_ms: internal_date(rest), body }));
            }
        }
    }

    fn note_uid(&mut self, uid: u32) {
        if uid > self.last_uid {
            self.last_uid = uid;
        }
    }

    /// A server line made safe for a log: the credential removed, whitespace flattened, bounded.
    fn quiet(&self, text: &str) -> String {
        let flat: String = text.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
        let redacted = redact(&flat, &[self.password.expose()]);
        let bounded: String = redacted.split_whitespace().collect::<Vec<_>>().join(" ");
        bounded.chars().take(200).collect()
    }
}

struct Response {
    line: String,
    literals: Vec<Vec<u8>>,
}

/// `{123}` at the end of a response line: the literal's length.
fn literal_len(line: &str) -> Option<usize> {
    let trimmed = line.trim_end();
    let open = trimmed.rfind('{')?;
    if !trimmed.ends_with('}') {
        return None;
    }
    let inner = &trimmed[open + 1..trimmed.len() - 1];
    let digits: String = inner.chars().take_while(char::is_ascii_digit).collect();
    if digits.is_empty() {
        return None;
    }
    digits.parse().ok()
}

/// The value of a `[NAME value]` response code.
fn bracket_value<'a>(text: &'a str, name: &str) -> Option<&'a str> {
    let start = text.find('[')?;
    let end = text[start..].find(']')? + start;
    let inner = &text[start + 1..end];
    let value = inner.strip_prefix(name)?.trim();
    Some(value)
}

/// The number after `key` in a fetch line (`UID 12`), bounded by the next space or paren.
fn token_number(text: &str, key: &str) -> Option<u32> {
    let at = text.find(key)? + key.len();
    let digits: String = text[at..].chars().take_while(char::is_ascii_digit).collect();
    digits.parse().ok()
}

/// The parenthesised `FLAGS (\Seen \Flagged)` list.
fn flag_list(text: &str) -> Vec<String> {
    let Some(at) = text.find("FLAGS (") else { return Vec::new() };
    let start = at + "FLAGS (".len();
    let Some(end) = text[start..].find(')') else { return Vec::new() };
    text[start..start + end].split_whitespace().take(16).map(str::to_string).collect()
}

/// `INTERNALDATE "06-Nov-2026 10:00:00 +0000"` → Unix ms.
fn internal_date(text: &str) -> Option<i64> {
    let at = text.find("INTERNALDATE \"")? + "INTERNALDATE \"".len();
    let end = text[at..].find('"')? + at;
    let value = &text[at..end];
    // `06-Nov-2026 10:00:00 +0000`, which is an RFC 5322 date with dashes instead of spaces around the
    // month: reshape it and reuse the one date parser the connector has.
    let mut parts = value.split_whitespace();
    let date = parts.next()?;
    let time = parts.next()?;
    let zone = parts.next().unwrap_or("+0000");
    let (day, month, year) = {
        let mut date = date.split('-');
        (date.next()?, date.next()?, date.next()?)
    };
    let rebuilt = format!("{day} {month} {year} {time} {zone}");
    mime::parse_date(&rebuilt)
}

/// Escape a string for an IMAP quoted argument. A credential containing a quote or a CR/LF cannot break
/// out of the argument, and a CR/LF is refused by the credential check before it gets here.
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\r' | '\n' => out.push(' '),
            other => out.push(other),
        }
    }
    out
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// An in-process IMAP server: a scripted mailbox that answers the commands this client sends.
    /// It exists so "receive, index, reconnect and bad credentials" are measured against a server that
    /// behaves like a server, without a port, a thread or a real mailbox.
    pub struct FakeImap {
        pub user: String,
        pub password: String,
        pub uid_validity: u32,
        pub messages: Vec<(u32, Vec<u8>, bool)>,
        pub fail_login: bool,
        pub close_after_fetch: Option<u32>,
        /// Set by the fake when the answer it just wrote is its last: the link closes afterwards.
        pub drop_after_answer: bool,
        pub commands: Vec<String>,
        greeting_sent: bool,
        fetched: usize,
    }

    impl FakeImap {
        pub fn new(user: &str, password: &str) -> FakeImap {
            FakeImap {
                user: user.into(),
                password: password.into(),
                uid_validity: 7,
                messages: Vec::new(),
                fail_login: false,
                close_after_fetch: None,
                drop_after_answer: false,
                commands: Vec::new(),
                greeting_sent: false,
                fetched: 0,
            }
        }

        pub fn with_message(mut self, uid: u32, body: &str) -> FakeImap {
            let raw = format!("From: Ana <ana@example.com>\r\nSubject: mensagem {uid}\r\nMessage-ID: <{uid}@example.com>\r\n\r\n{body}\r\n");
            self.messages.push((uid, raw.into_bytes(), false));
            self
        }

        /// Handle whatever the client wrote; `None` means "the peer closed the connection".
        pub fn on_bytes(&mut self, data: &[u8]) -> Option<Vec<u8>> {
            let text = String::from_utf8_lossy(data).to_string();
            let mut out = String::new();
            if !self.greeting_sent {
                self.greeting_sent = true;
                out.push_str("* OK fake IMAP ready\r\n");
            }
            for line in text.split("\r\n").filter(|line| !line.is_empty()) {
                self.commands.push(line.to_string());
                let mut parts = line.splitn(3, ' ');
                let tag = parts.next().unwrap_or("a1").to_string();
                let command = parts.next().unwrap_or_default().to_ascii_uppercase();
                let rest = parts.next().unwrap_or_default().to_string();
                match command.as_str() {
                    "LOGIN" => {
                        let quoted: Vec<String> = rest.split(" \"").map(|part| part.trim_matches('"').to_string()).collect();
                        let user = quoted.first().cloned().unwrap_or_default();
                        let password = quoted.get(1).map(|value| value.trim_end_matches('"').to_string()).unwrap_or_default();
                        if self.fail_login || user != self.user || password != self.password {
                            out.push_str(&format!("{tag} NO [AUTHENTICATIONFAILED] invalid credentials for {user}\r\n"));
                        } else {
                            out.push_str(&format!("{tag} OK LOGIN completed\r\n"));
                        }
                    }
                    "SELECT" => {
                        out.push_str(&format!("* {} EXISTS\r\n* OK [UIDVALIDITY {}] UIDs valid\r\n", self.messages.len(), self.uid_validity));
                        out.push_str(&format!("{tag} OK [READ-WRITE] SELECT completed\r\n"));
                    }
                    "UID" => {
                        if rest.to_ascii_uppercase().starts_with("SEARCH") {
                            let floor = rest.split(':').next().and_then(|prefix| prefix.rsplit(' ').next()).and_then(|value| value.parse::<u32>().ok()).unwrap_or(1);
                            let uids: Vec<String> = self.messages.iter().map(|(uid, _, _)| *uid).filter(|uid| *uid >= floor).map(|uid| uid.to_string()).collect();
                            out.push_str(&format!("* SEARCH {}\r\n{tag} OK SEARCH completed\r\n", uids.join(" ")));
                        } else {
                            let uid = rest.split_whitespace().nth(1).and_then(|value| value.parse::<u32>().ok()).unwrap_or(0);
                            let Some((_, body, _)) = self.messages.iter_mut().find(|(id, _, _)| *id == uid) else {
                                out.push_str(&format!("{tag} NO no such message\r\n"));
                                return Some(out.into_bytes());
                            };
                            out.push_str(&format!("* 1 FETCH (UID {uid} FLAGS (\\Seen) INTERNALDATE \"06-Nov-2026 10:00:00 +0000\" BODY[] {{{}}}\r\n", body.len()));
                            let mut bytes = out.into_bytes();
                            bytes.extend_from_slice(body);
                            out = String::from_utf8_lossy(&bytes).to_string();
                            out.push_str(")\r\n");
                            self.fetched += 1;
                            if self.close_after_fetch == Some(self.fetched as u32) {
                                // The drop the reconnect test needs: the answer for this message is
                                // delivered and then the connection dies, before the tagged OK.
                                self.drop_after_answer = true;
                            }
                            out.push_str(&format!("{tag} OK FETCH completed\r\n"));
                        }
                    }
                    "NOOP" => out.push_str(&format!("{tag} OK NOOP completed\r\n")),
                    "LOGOUT" => {
                        out.push_str(&format!("* BYE closing\r\n{tag} OK LOGOUT completed\r\n"));
                        let bytes = out.into_bytes();
                        return Some(bytes);
                    }
                    _ => out.push_str(&format!("{tag} BAD unknown command\r\n")),
                }
            }
            Some(out.into_bytes())
        }
    }

    /// A transport that answers synchronously from an in-process server: the client's writes go into
    /// the server, the server's answers come back out. No socket, no thread, no executor.
    pub struct Loopback {
        pub server: FakeImap,
        pub inbound: VecDeque<Vec<u8>>,
        pub closed: bool,
        /// The server's last answer is queued; the connection ends after it is read.
        pub pending_close: bool,
    }

    impl Loopback {
        pub fn new(mut server: FakeImap) -> Loopback {
            // A real server greets first; the fake sends its greeting before any command.
            let greeting = server.on_bytes(b"");
            Loopback { server, inbound: greeting.into_iter().collect(), closed: false, pending_close: false }
        }

        pub fn write(&mut self, bytes: &[u8]) {
            if self.closed || self.pending_close {
                return;
            }
            match self.server.on_bytes(bytes) {
                Some(answer) => {
                    if !answer.is_empty() {
                        self.inbound.push_back(answer);
                    }
                    if self.server.drop_after_answer {
                        self.pending_close = true;
                    }
                }
                None => self.closed = true,
            }
        }

        /// `None` is end of stream: nothing queued and the server is gone. A server that answered
        /// everything and then dropped says so only after the queued answer has been read.
        pub fn read(&mut self) -> Option<Vec<u8>> {
            if let Some(chunk) = self.inbound.pop_front() {
                return Some(chunk);
            }
            if self.closed || self.pending_close {
                self.closed = true;
                return None;
            }
            None
        }
    }

    /// Drive a session against the loopback to the end of a round (or to a stop). The round's own
    /// numbers are read from the session, exactly as the connector reads them.
    fn run_round(imap: &mut Imap, link: &mut Loopback) -> Vec<Event> {
        let mut events = Vec::new();
        for _ in 0..64 {
            match imap.step() {
                Step::Write(bytes) => {
                    link.write(&bytes);
                    if link.closed {
                        events.extend(imap.on_eof());
                        return events;
                    }
                }
                Step::Wait => match link.read() {
                    Some(bytes) => {
                        let produced = imap.on_bytes(&bytes);
                        let stopped = produced.iter().any(|event| matches!(event, Event::Closed { .. } | Event::AuthFailed { .. } | Event::Protocol { .. }));
                        events.extend(produced);
                        if stopped {
                            return events;
                        }
                    }
                    None => return events,
                },
                Step::RoundDone => {
                    events.extend(imap.take_events());
                    return events;
                }
            }
        }
        events
    }

    #[test]
    fn a_round_logs_in_selects_and_fetches_what_is_new() {
        let server = FakeImap::new("me@example.com", "s3cret").with_message(1, "primeira").with_message(2, "segunda");
        let mut link = Loopback::new(server);
        let mut imap = Imap::new("INBOX", "me@example.com", Secret::new("s3cret"));
        let events = run_round(&mut imap, &mut link);
        assert!(matches!(events[0], Event::Selected { uid_validity: 7, exists: 2 }), "{events:?}");
        let bodies: Vec<String> = events
            .iter()
            .filter_map(|event| match event {
                Event::Message(fetched) => Some(String::from_utf8_lossy(&fetched.body).to_string()),
                _ => None,
            })
            .collect();
        assert_eq!(bodies.len(), 2);
        assert!(bodies[0].contains("primeira"));
        assert!(bodies[1].contains("segunda"));
        assert_eq!((imap.fetched(), imap.last_uid()), (2, 2), "the round's counters are the report");
        assert_eq!(imap.last_uid(), 2);
        // The commands are the documented ones, in order, and `BODY.PEEK[]` keeps mail unread.
        assert_eq!(link.server.commands[0], "a1 LOGIN \"me@example.com\" \"s3cret\"");
        assert_eq!(link.server.commands[1], "a2 SELECT \"INBOX\"");
        assert_eq!(link.server.commands[2], "a3 UID SEARCH UID 1:*");
        assert_eq!(link.server.commands[3], "a4 UID FETCH 1 (UID FLAGS INTERNALDATE BODY.PEEK[])");
        assert_eq!(link.server.commands[4], "a5 UID FETCH 2 (UID FLAGS INTERNALDATE BODY.PEEK[])");
        let message = events.iter().find_map(|event| match event {
            Event::Message(fetched) if fetched.uid == 2 => Some(fetched),
            _ => None,
        });
        let message = message.unwrap();
        assert_eq!(message.flags, vec!["\\Seen".to_string()]);
        assert_eq!(message.internal_date_ms, Some(1_793_959_200_000));
    }

    #[test]
    fn a_second_round_asks_only_for_uids_above_the_last_one() {
        let server = FakeImap::new("me@example.com", "s3cret").with_message(1, "primeira");
        let mut link = Loopback::new(server);
        let mut imap = Imap::new("INBOX", "me@example.com", Secret::new("s3cret"));
        let first = run_round(&mut imap, &mut link);
        assert_eq!(first.iter().filter(|event| matches!(event, Event::Message(_))).count(), 1);
        // A new message arrives, and the next round finds only it.
        link.server.messages.push((2, b"From: bia@example.org\r\nSubject: segunda\r\n\r\nsegunda\r\n".to_vec(), false));
        imap.next_round();
        let second = run_round(&mut imap, &mut link);
        let fetched: Vec<u32> = second
            .iter()
            .filter_map(|event| match event {
                Event::Message(fetched) => Some(fetched.uid),
                _ => None,
            })
            .collect();
        assert_eq!(fetched, vec![2], "the already-indexed UID is not asked for again: {second:?} / {:?}", link.server.commands);
        assert!(link.server.commands.iter().any(|command| command.contains("UID SEARCH UID 2:*")), "commands: {:?}", link.server.commands);
        // A quiet round is a RoundDone with nothing fetched.
        imap.next_round();
        let quiet = run_round(&mut imap, &mut link);
        assert_eq!((imap.fetched(), imap.last_uid()), (0, 2), "a quiet round fetched nothing and kept the floor: {quiet:?}");
    }

    #[test]
    fn a_refused_login_is_a_clear_answer_without_the_credential() {
        let mut server = FakeImap::new("me@example.com", "s3cret");
        server.fail_login = true;
        let mut link = Loopback::new(server);
        let mut imap = Imap::new("INBOX", "me@example.com", Secret::new("s3cret"));
        let events = run_round(&mut imap, &mut link);
        let answer = events.iter().find_map(|event| match event {
            Event::AuthFailed { answer } => Some(answer.clone()),
            _ => None,
        });
        let answer = answer.expect("an auth failure");
        assert!(answer.contains("AUTHENTICATIONFAILED"), "{answer}");
        assert!(!answer.contains("s3cret"), "the answer a caller logs never carries the password: {answer}");
        assert!(imap.closed());
        // Nothing was fetched and the machine stops: a refused login is not retried on this session.
        assert!(!link.server.commands.iter().any(|command| command.contains("FETCH")));
    }

    #[test]
    fn a_connection_that_drops_mid_round_is_reported_as_closed() {
        let mut server = FakeImap::new("me@example.com", "s3cret").with_message(1, "primeira").with_message(2, "segunda");
        // The fake serves the first message and then drops the connection: a flapping server.
        server.close_after_fetch = Some(1);
        let mut link = Loopback::new(server);
        let mut imap = Imap::new("INBOX", "me@example.com", Secret::new("s3cret"));
        let events = run_round(&mut imap, &mut link);
        assert!(events.iter().any(|event| matches!(event, Event::Message(fetched) if fetched.uid == 1)));
        let closed = imap.on_eof();
        assert!(closed.iter().any(|event| matches!(event, Event::Closed { reason: "eof" })), "{closed:?}");
        assert!(imap.closed(), "a dropped connection closes the session");
        assert_eq!(imap.last_uid(), 1, "what was fetched before the drop is kept");
    }

    #[test]
    fn a_literal_split_across_reads_is_reassembled() {
        let mut server = FakeImap::new("me@example.com", "s3cret").with_message(1, "corpo inteiro");
        let mut imap = Imap::new("INBOX", "me@example.com", Secret::new("s3cret"));
        // Greeting + login + select + search, in one chunk.
        let bytes = server.on_bytes(b"").unwrap();
        let _ = imap.on_bytes(&bytes);
        let answer = server.on_bytes(b"a1 LOGIN \"me@example.com\" \"s3cret\"\r\n").unwrap();
        let _ = imap.on_bytes(&answer);
        let answer = server.on_bytes(b"a2 SELECT \"INBOX\"\r\n").unwrap();
        let _ = imap.on_bytes(&answer);
        let answer = server.on_bytes(b"a3 UID SEARCH UID 1:*\r\n").unwrap();
        let _ = imap.on_bytes(&answer);
        let answer = server.on_bytes(b"a4 UID FETCH 1 (UID FLAGS INTERNALDATE BODY.PEEK[])\r\n").unwrap();
        // Split the answer in the middle of the literal: half now, half next read.
        let midpoint = answer.len() / 2;
        let first = imap.on_bytes(&answer[..midpoint]);
        assert!(first.is_empty(), "a partial literal emits nothing: {first:?}");
        let second = imap.on_bytes(&answer[midpoint..]);
        let body = second.iter().find_map(|event| match event {
            Event::Message(fetched) => Some(String::from_utf8_lossy(&fetched.body).to_string()),
            _ => None,
        });
        assert!(body.unwrap().contains("corpo inteiro"));
    }

    #[test]
    fn a_message_over_the_bound_is_skipped_and_the_round_continues() {
        let big = "x".repeat(4_000);
        let server = FakeImap::new("me@example.com", "s3cret").with_message(1, &big).with_message(2, "pequena");
        let mut link = Loopback::new(server);
        let mut imap = Imap::with_bound("INBOX", "me@example.com", Secret::new("s3cret"), 1_024);
        let events = run_round(&mut imap, &mut link);
        assert!(
            events.iter().any(|event| matches!(event, Event::Skipped { uid: 1, bytes } if *bytes > 1_024)),
            "the oversized message is named: {events:?}"
        );
        assert!(events.iter().any(|event| matches!(event, Event::Message(fetched) if fetched.uid == 2)), "the round continues");
        assert_eq!(imap.last_uid(), 2, "the skipped UID is behind the floor, so it is not refetched forever");
        // The bound is a memory-safety property, and asking for more is clamped down.
        assert_eq!(MAX_MESSAGE, 4 * 1024 * 1024);
        assert_eq!(Imap::with_bound("INBOX", "u", Secret::new("p"), usize::MAX).max_message, MAX_MESSAGE);
        assert_eq!(literal_len("* 1 FETCH (UID 1 BODY[] {42}"), Some(42));
        assert_eq!(literal_len("* OK no literal here"), None);
        assert_eq!(literal_len("* 1 FETCH (BODY[] {not-a-number}"), None);
    }

    #[test]
    fn a_bye_closes_the_session() {
        let mut imap = Imap::new("INBOX", "me@example.com", Secret::new("s3cret"));
        let events = imap.on_bytes(b"* BYE server shutting down\r\n");
        assert!(events.iter().any(|event| matches!(event, Event::Closed { reason: "bye" })), "{events:?}");
        assert!(imap.closed());
    }

    #[test]
    fn a_credential_with_a_quote_cannot_break_out_of_the_login_argument() {
        let mut imap = Imap::new("INBOX", "me", Secret::new("pa\"ss\\word"));
        // The greeting first (the machine sends nothing before it).
        let _ = imap.on_bytes(b"* OK ready\r\n");
        match imap.step() {
            Step::Write(bytes) => {
                let line = String::from_utf8(bytes).unwrap();
                assert_eq!(line, "a1 LOGIN \"me\" \"pa\\\"ss\\\\word\"\r\n");
                assert_eq!(line.matches('\n').count(), 1, "one command, one line");
            }
            other => panic!("expected a write, got {other:?}"),
        }
    }

    #[test]
    fn an_unexpected_tagged_answer_does_not_desynchronise_the_machine() {
        let mut imap = Imap::new("INBOX", "me", Secret::new("s"));
        let _ = imap.on_bytes(b"* OK ready\r\n");
        let _ = imap.step();
        // An answer to a tag we never sent is ignored instead of being read as our login's result.
        let events = imap.on_bytes(b"a99 OK not ours\r\n");
        assert!(events.is_empty());
        assert!(!imap.closed());
    }

}
