//! SMTP submission, as a sans-I/O client, for the same reason [`crate::imap`] is one: the guest owns the
//! TLS stream, this owns the dialog.
//!
//! The dialog is short and strict: `EHLO`, `AUTH LOGIN` (the server must offer it - this connector does
//! not fall back to an unauthenticated relay), `MAIL FROM`, one `RCPT TO` per recipient, `DATA`, the
//! message with dots stuffed and a final `.`, then `QUIT`. Every step is one write and one reply, so the
//! machine is a list of states rather than a parser.
//!
//! Failures are classified the way the queue needs them: `4xx` is temporary (the worker settles the job
//! as a retryable failure and the queue's backoff applies), `5xx` is a permanent refusal (the same
//! settlement, but the reason says which), and a refused credential is the one answer that reports
//! `email_auth_failed` so an operator knows to change the vault, not the mail.
use base64::Engine as _;
use wa_email_outbox::{Mailbox, Secret, Verified};

use crate::compose::Composed;

/// Most lines of one reply this client will read (a server's multiline greeting is bounded).
const MAX_REPLY_LINES: usize = 32;

/// What the driver should do next.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Step {
    Write(Vec<u8>),
    Wait,
    Done,
}

/// What the submission did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// The server accepted the message. `message_id` is the one this client put in the header.
    Sent { message_id: String, recipients: usize },
    /// The submission was refused. `code` is a stable word (`email_auth_failed`,
    /// `email_recipient_refused`, `email_smtp_temporary`, `email_smtp_no_auth`, `email_smtp_protocol`),
    /// `detail` is the server's own line with the credential removed and the length bounded.
    Refused { code: &'static str, detail: String, retryable: bool },
    /// The connection ended before an answer.
    Closed { reason: &'static str },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Greeting,
    Ehlo,
    AuthStart,
    AuthUser,
    AuthPassword,
    MailFrom,
    RcptTo,
    Data,
    Body,
    Quit,
    Done,
    Closed,
}

/// One submission.
pub struct Smtp {
    /// What this client calls itself in `EHLO`.
    host_name: String,
    user: String,
    password: Secret,
    from: Mailbox,
    recipients: Vec<String>,
    /// The composed message, CRLF-terminated.
    message: Vec<u8>,
    message_id: String,
    state: State,
    /// A command is on the wire and its reply has not been read.
    awaiting: bool,
    out: Vec<u8>,
    inbuf: Vec<u8>,
    /// A multiline reply being assembled (`250-…` lines until `250 …`).
    reply: String,
    /// The number of the RCPT TO in flight, so a refusal names the recipient's position (never its
    /// address).
    rcpt_index: usize,
    events: Vec<Event>,
}

impl Smtp {
    /// Prepare one submission from a validated request and the bytes composed for it.
    pub fn new(host_name: &str, user: &str, password: Secret, from: &Mailbox, verified: &Verified, composed: &Composed) -> Smtp {
        let recipients = verified.recipients().iter().map(|mailbox| mailbox.addr()).collect();
        let mut message = composed.bytes.clone();
        if !message.ends_with(b"\r\n") {
            message.extend_from_slice(b"\r\n");
        }
        Smtp {
            host_name: host_name.to_string(),
            user: user.to_string(),
            password,
            from: from.clone(),
            recipients,
            message,
            message_id: composed.message_id.clone(),
            state: State::Greeting,
            awaiting: false,
            out: Vec::new(),
            inbuf: Vec::new(),
            reply: String::new(),
            rcpt_index: 0,
            events: Vec::new(),
        }
    }

    /// What the driver should do next.
    pub fn step(&mut self) -> Step {
        if matches!(self.state, State::Done | State::Closed) {
            return Step::Done;
        }
        if !self.out.is_empty() {
            return Step::Write(std::mem::take(&mut self.out));
        }
        if self.awaiting {
            return Step::Wait;
        }
        match self.state {
            State::Greeting => Step::Wait,
            State::Ehlo => self.command(&format!("EHLO {}\r\n", self.host_name)),
            State::AuthStart => self.command("AUTH LOGIN\r\n"),
            State::AuthUser => self.command(&format!("{}\r\n", base64::engine::general_purpose::STANDARD.encode(self.user.as_bytes()))),
            State::AuthPassword => self.command(&format!("{}\r\n", base64::engine::general_purpose::STANDARD.encode(self.password.expose().as_bytes()))),
            State::MailFrom => self.command(&format!("MAIL FROM:<{}>\r\n", self.from.addr())),
            State::RcptTo => match self.recipients.get(self.rcpt_index) {
                Some(recipient) => self.command(&format!("RCPT TO:<{recipient}>\r\n")),
                None => {
                    self.state = State::Data;
                    self.command("DATA\r\n")
                }
            },
            State::Data => self.command("DATA\r\n"),
            State::Body => {
                // The state stays `Body` until the server answers the data (`250`): setting it to `Quit`
                // here would send a QUIT and report success before the message was accepted.
                let mut payload = dot_stuff(&self.message);
                payload.extend_from_slice(b".\r\n");
                self.awaiting = true;
                Step::Write(payload)
            }
            State::Quit => self.command("QUIT\r\n"),
            State::Done | State::Closed => Step::Done,
        }
    }

    /// Feed whatever the server said.
    pub fn on_bytes(&mut self, data: &[u8]) -> Vec<Event> {
        if self.state == State::Closed {
            return Vec::new();
        }
        self.inbuf.extend_from_slice(data);
        while let Some(reply) = self.take_reply() {
            self.handle(reply);
            if self.state == State::Closed {
                break;
            }
        }
        std::mem::take(&mut self.events)
    }

    /// The transport reached end of stream.
    pub fn on_eof(&mut self) -> Vec<Event> {
        if self.state != State::Closed {
            self.state = State::Closed;
            self.events.push(Event::Closed { reason: "eof" });
        }
        std::mem::take(&mut self.events)
    }

    /// The driver failed on its own (a write error): nothing was confirmed.
    pub fn abandon(&mut self, reason: &'static str) -> Vec<Event> {
        if self.state != State::Closed {
            self.state = State::Closed;
            self.events.push(Event::Closed { reason });
        }
        std::mem::take(&mut self.events)
    }

    fn command(&mut self, line: &str) -> Step {
        self.awaiting = true;
        self.out.extend_from_slice(line.as_bytes());
        Step::Write(std::mem::take(&mut self.out))
    }

    /// One complete reply: every `NNN-…` line plus the final `NNN …` line.
    fn take_reply(&mut self) -> Option<String> {
        loop {
            let end = crate::find(&self.inbuf, b"\r\n")?;
            let line = String::from_utf8_lossy(&self.inbuf[..end]).to_string();
            self.inbuf.drain(..end + 2);
            self.reply.push_str(&line);
            self.reply.push('\n');
            if self.reply.lines().count() > MAX_REPLY_LINES {
                let text = std::mem::take(&mut self.reply);
                return Some(text);
            }
            // `250-text` continues the reply; `250 text` or a bare `250` ends it.
            let continues = line.len() >= 4 && line.as_bytes()[3] == b'-';
            if !continues {
                return Some(std::mem::take(&mut self.reply));
            }
        }
    }

    fn handle(&mut self, reply: String) {
        self.awaiting = false;
        let code = reply.trim_start().get(..3).and_then(|code| code.parse::<u16>().ok()).unwrap_or(0);
        match self.state {
            State::Greeting => {
                if code == 220 {
                    self.state = State::Ehlo;
                } else {
                    self.refuse("email_smtp_protocol", &reply, false);
                }
            }
            State::Ehlo => {
                if code != 250 {
                    self.refuse("email_smtp_protocol", &reply, false);
                    return;
                }
                let advertises_login = reply.to_ascii_uppercase().contains("AUTH") && reply.to_ascii_uppercase().contains("LOGIN");
                if advertises_login {
                    self.state = State::AuthStart;
                } else {
                    // No AUTH LOGIN, no submission: this connector will not relay anonymously, and it
                    // does not guess at another mechanism.
                    self.refuse("email_smtp_no_auth", "the server does not offer AUTH LOGIN", false);
                }
            }
            State::AuthStart => {
                // 334 = "here is the username prompt".
                if code == 334 {
                    self.state = State::AuthUser;
                } else {
                    self.refuse(classify(code, "email_auth_failed"), &reply, (400..500).contains(&code));
                }
            }
            State::AuthUser => {
                if code == 334 {
                    self.state = State::AuthPassword;
                } else {
                    self.refuse(classify(code, "email_auth_failed"), &reply, (400..500).contains(&code));
                }
            }
            State::AuthPassword => {
                if code == 235 {
                    self.state = State::MailFrom;
                } else {
                    // 535 is the wrong credential; 454 is a temporary lockout.
                    let code_word = if code == 535 { "email_auth_failed" } else { classify(code, "email_auth_failed") };
                    self.refuse(code_word, &reply, (400..500).contains(&code));
                }
            }
            State::MailFrom => {
                if code == 250 {
                    self.state = State::RcptTo;
                    self.rcpt_index = 0;
                } else {
                    self.refuse(classify(code, "email_sender_refused"), &reply, (400..500).contains(&code));
                }
            }
            State::RcptTo => {
                if code == 250 || code == 251 {
                    self.rcpt_index += 1;
                    if self.rcpt_index >= self.recipients.len() {
                        self.state = State::Data;
                    }
                } else {
                    let retryable = (400..500).contains(&code);
                    self.refuse(classify(code, "email_recipient_refused"), &reply, retryable);
                }
            }
            State::Data => {
                if code == 354 {
                    self.state = State::Body;
                } else {
                    self.refuse(classify(code, "email_smtp_protocol"), &reply, (400..500).contains(&code));
                }
            }
            State::Body => {
                if code == 250 {
                    self.state = State::Quit;
                } else {
                    self.refuse(classify(code, "email_smtp_refused"), &reply, (400..500).contains(&code));
                }
            }
            State::Quit => {
                self.state = State::Done;
                let event = Event::Sent { message_id: self.message_id.clone(), recipients: self.recipients.len() };
                self.events.push(event);
            }
            State::Done | State::Closed => {}
        }
    }

    fn refuse(&mut self, code: &'static str, reply: &str, retryable: bool) {
        self.state = State::Closed;
        self.events.push(Event::Refused { code, detail: self.quiet(reply), retryable });
    }

    /// The server's line as a caller may log it: credential removed, whitespace flattened, bounded.
    fn quiet(&self, reply: &str) -> String {
        let flat: String = reply.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
        let redacted = wa_email_outbox::redact(&flat, &[self.password.expose()]);
        let bounded: String = redacted.split_whitespace().collect::<Vec<_>>().join(" ");
        bounded.chars().take(200).collect()
    }
}

/// The stable word for a refusal: `4xx` is a temporary failure, `5xx` the caller's own.
fn classify(code: u16, five_xx: &'static str) -> &'static str {
    if (400..500).contains(&code) {
        "email_smtp_temporary"
    } else {
        five_xx
    }
}

/// Dot-stuffing: a line that starts with `.` gets one more, so the message cannot end early. The final
/// `.` is added by the caller.
pub fn dot_stuff(message: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(message.len() + 8);
    let mut at_line_start = true;
    for byte in message {
        if at_line_start && *byte == b'.' {
            out.push(b'.');
        }
        out.push(*byte);
        at_line_start = *byte == b'\n';
    }
    out
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::compose::compose;
    use wa_email_outbox::{Attachment, Request};

    /// An in-process SMTP submission server: `EHLO`, `AUTH LOGIN`, `MAIL`, `RCPT`, `DATA`.
    pub struct FakeSmtp {
        /// The account the fake will accept. `user` is checked in the LOGIN dialog.
        pub user: String,
        pub password: String,
        pub offer_auth: bool,
        pub reject_recipient: Option<String>,
        pub temporary: bool,
        pub data: Vec<u8>,
        pub commands: Vec<String>,
        pub envelope: Vec<String>,
        pub recipients: Vec<String>,
        greeted: bool,
        auth_stage: usize,
        in_data: bool,
        closed: bool,
    }

    impl FakeSmtp {
        pub fn new(user: &str, password: &str) -> FakeSmtp {
            FakeSmtp {
                user: user.into(),
                password: password.into(),
                offer_auth: true,
                reject_recipient: None,
                temporary: false,
                data: Vec::new(),
                commands: Vec::new(),
                envelope: Vec::new(),
                recipients: Vec::new(),
                greeted: false,
                auth_stage: 0,
                in_data: false,
                closed: false,
            }
        }

        pub fn on_bytes(&mut self, data: &[u8]) -> Option<Vec<u8>> {
            if self.in_data {
                self.data.extend_from_slice(data);
                if self.data.ends_with(b"\r\n.\r\n") {
                    self.in_data = false;
                    let truncated = &self.data[..self.data.len() - 3];
                    let unstuffed = unstuff(truncated);
                    self.data = unstuffed;
                    return Some(b"250 2.0.0 Ok: queued as 4F3A2C\r\n".to_vec());
                }
                return Some(Vec::new());
            }
            let text = String::from_utf8_lossy(data).to_string();
            let mut out = String::new();
            if !self.greeted {
                self.greeted = true;
                out.push_str("220 fake ESMTP ready\r\n");
            }
            for line in text.split("\r\n").filter(|line| !line.is_empty()) {
                self.commands.push(line.to_string());
                let upper = line.to_ascii_uppercase();
                if self.auth_stage == 1 || self.auth_stage == 2 {
                    let decoded = String::from_utf8(base64::engine::general_purpose::STANDARD.decode(line.trim()).unwrap_or_default()).unwrap_or_default();
                    if self.auth_stage == 1 {
                        if decoded != self.user {
                            out.push_str("535 5.7.8 Authentication credentials invalid\r\n");
                            self.auth_stage = 3;
                            continue;
                        }
                        self.envelope.push(format!("user:{decoded}"));
                        self.auth_stage = 2;
                        out.push_str("334 UGFzc3dvcmQ6\r\n");
                        continue;
                    }
                    self.envelope.push("password:given".to_string());
                    self.auth_stage = 3;
                    if self.temporary {
                        out.push_str("454 4.7.0 temporary authentication failure\r\n");
                    } else if decoded == self.password {
                        out.push_str("235 2.7.0 Authentication successful\r\n");
                    } else {
                        out.push_str("535 5.7.8 Authentication credentials invalid\r\n");
                    }
                    continue;
                }
                if upper.starts_with("EHLO") {
                    if self.offer_auth {
                        out.push_str("250-fake greets you\r\n250-SIZE 35882577\r\n250-AUTH LOGIN PLAIN\r\n250 8BITMIME\r\n");
                    } else {
                        out.push_str("250-fake greets you\r\n250 8BITMIME\r\n");
                    }
                } else if upper.starts_with("AUTH LOGIN") {
                    self.auth_stage = 1;
                    out.push_str("334 VXNlcm5hbWU6\r\n");
                } else if upper.starts_with("MAIL FROM:") {
                    self.envelope.push(line.to_string());
                    out.push_str("250 2.1.0 Ok\r\n");
                } else if upper.starts_with("RCPT TO:") {
                    // The angle-addr inside `RCPT TO:<a@b>`, case-insensitively.
                    let address = line["RCPT TO:".len()..].trim().trim_start_matches('<').trim_end_matches('>').to_string();
                    if self.reject_recipient.as_deref() == Some(address.as_str()) {
                        out.push_str("550 5.1.1 <recipient> unknown user\r\n");
                    } else {
                        self.recipients.push(address);
                        out.push_str("250 2.1.5 Ok\r\n");
                    }
                } else if upper == "DATA" {
                    self.in_data = true;
                    out.push_str("354 End data with <CR><LF>.<CR><LF>\r\n");
                } else if upper == "QUIT" {
                    out.push_str("221 2.0.0 Bye\r\n");
                    self.closed = true;
                    return Some(out.into_bytes());
                } else {
                    out.push_str("502 5.5.2 Command not implemented\r\n");
                }
            }
            Some(out.into_bytes())
        }
    }

    fn unstuff(data: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(data.len());
        let mut at_line_start = true;
        let mut index = 0usize;
        while index < data.len() {
            if at_line_start && data[index] == b'.' && data.get(index + 1) == Some(&b'.') {
                out.push(b'.');
                index += 2;
                at_line_start = false;
                continue;
            }
            out.push(data[index]);
            at_line_start = data[index] == b'\n';
            index += 1;
        }
        out
    }

    fn verified(to: &[&str], subject: &str, body: &str) -> Verified {
        Request { to: to.iter().map(|value| value.to_string()).collect(), cc: Vec::new(), subject: subject.into(), body: body.into(), in_reply_to: None, attachments: Vec::new() }
            .validate()
            .expect("a valid request")
    }

    /// An in-process link for the connector's tests: the client's writes go to the fake server, whose
    /// answers come straight back.
    pub struct SmtpLoopback {
        pub server: FakeSmtp,
        pub inbound: std::collections::VecDeque<Vec<u8>>,
        pub closed: bool,
    }

    impl SmtpLoopback {
        pub fn new(mut server: FakeSmtp) -> SmtpLoopback {
            let greeting = server.on_bytes(b"");
            SmtpLoopback { server, inbound: greeting.into_iter().collect(), closed: false }
        }
    }

    /// Drive one submission against the fake, the way the guest drives it over the kernel stream:
    /// writes go to the server, the server's answers come back to the client, and the loop stops when
    /// the client has an outcome (or nothing more can happen).
    fn submit(smtp: &mut Smtp, server: &mut FakeSmtp) -> Vec<Event> {
        let mut inbound: std::collections::VecDeque<Vec<u8>> = server.on_bytes(b"").into_iter().collect();
        let mut events = Vec::new();
        let finished = |events: &Vec<Event>| events.iter().any(|event| matches!(event, Event::Sent { .. } | Event::Refused { .. } | Event::Closed { .. }));
        for _ in 0..64 {
            match smtp.step() {
                Step::Write(bytes) => {
                    if let Some(answer) = server.on_bytes(&bytes) {
                        if !answer.is_empty() {
                            events.extend(smtp.on_bytes(&answer));
                        }
                    } else {
                        events.extend(smtp.on_eof());
                    }
                }
                Step::Wait => match inbound.pop_front() {
                    Some(answer) => events.extend(smtp.on_bytes(&answer)),
                    None => return events,
                },
                Step::Done => break,
            }
            if finished(&events) {
                return events;
            }
        }
        events
    }

    #[test]
    fn a_message_is_authenticated_and_delivered_to_the_fake() {
        let from = Mailbox::parse("me@example.com").unwrap();
        let verified = verified(&["ana@example.com", "bia@example.org"], "Relatório", "Segue o relatório.");
        let composed = compose(&from, &verified, "dedupe", 1_793_959_200_000);
        let mut smtp = Smtp::new("client.example.com", "me@example.com", Secret::new("s3cret"), &from, &verified, &composed);
        let mut server = FakeSmtp::new("me@example.com", "s3cret");
        let events = submit(&mut smtp, &mut server);
        let sent = events.iter().find_map(|event| match event {
            Event::Sent { message_id, recipients } => Some((message_id.clone(), *recipients)),
            _ => None,
        });
        let (message_id, recipients) = sent.expect("a delivered message");
        assert_eq!(message_id, composed.message_id);
        assert_eq!(recipients, 2);
        // The fake received exactly the composed bytes, after dot-stuffing was undone.
        assert_eq!(server.data, composed.bytes);
        assert_eq!(server.recipients, vec!["ana@example.com".to_string(), "bia@example.org".to_string()]);
        assert_eq!(server.envelope[0], "user:me@example.com");
        assert_eq!(server.envelope[1], "password:given", "the envelope log records that a password was sent, not what it was");
        assert!(server.commands[0].starts_with("EHLO "));
        assert!(server.commands.contains(&"AUTH LOGIN".to_string()));
        assert_eq!(server.commands.iter().filter(|command| command.starts_with("RCPT TO:")).count(), 2);
        assert!(server.commands.iter().any(|command| command == "DATA"));
        assert_eq!(server.commands.last().map(String::as_str), Some("QUIT"));
        // Nothing in the dialog carried the credential in the clear.
        assert!(!server.commands.iter().any(|command| command.contains("s3cret")));
    }

    #[test]
    fn a_wrong_credential_is_a_clear_error_without_the_secret() {
        let from = Mailbox::parse("me@example.com").unwrap();
        let verified = verified(&["ana@example.com"], "s", "b");
        let composed = compose(&from, &verified, "d", 0);
        let mut smtp = Smtp::new("client.example.com", "me@example.com", Secret::new("wrong-password"), &from, &verified, &composed);
        let mut server = FakeSmtp::new("me@example.com", "the-right-one");
        let events = submit(&mut smtp, &mut server);
        let refusal = events.iter().find_map(|event| match event {
            Event::Refused { code, detail, retryable } => Some((*code, detail.clone(), *retryable)),
            _ => None,
        });
        let (code, detail, retryable) = refusal.expect("an auth refusal");
        assert_eq!(code, "email_auth_failed");
        assert!(!retryable, "the same credential will not start working");
        assert!(detail.contains("535"), "{detail}");
        assert!(!detail.contains("wrong-password"), "the detail a caller logs never carries the password: {detail}");
        // Nothing was delivered: no DATA was sent.
        assert!(!server.commands.iter().any(|command| command == "DATA"));
    }

    #[test]
    fn a_refused_recipient_a_temporary_failure_and_a_missing_auth_are_named() {
        let from = Mailbox::parse("me@example.com").unwrap();
        let verified = verified(&["nobody@example.com"], "s", "b");
        let composed = compose(&from, &verified, "d", 0);
        let mut server = FakeSmtp::new("me@example.com", "s3cret");
        server.reject_recipient = Some("nobody@example.com".to_string());
        let mut smtp = Smtp::new("client", "me@example.com", Secret::new("s3cret"), &from, &verified, &composed);
        let events = submit(&mut smtp, &mut server);
        match events.iter().find(|event| matches!(event, Event::Refused { .. })) {
            Some(Event::Refused { code, retryable, detail }) => {
                assert_eq!(*code, "email_recipient_refused");
                assert!(!retryable, "a 550 will not change");
                assert!(detail.contains("unknown user"), "{detail}");
            }
            other => panic!("expected a recipient refusal, got {other:?}"),
        }

        // A 4xx is retryable: the queue's backoff, not a dead letter on the first answer.
        let mut server = FakeSmtp::new("me@example.com", "s3cret");
        server.temporary = true;
        let mut smtp = Smtp::new("client", "me@example.com", Secret::new("s3cret"), &from, &verified, &composed);
        let events = submit(&mut smtp, &mut server);
        match events.iter().find(|event| matches!(event, Event::Refused { .. })) {
            Some(Event::Refused { code, retryable, .. }) => {
                assert_eq!(*code, "email_smtp_temporary");
                assert!(*retryable, "454 is temporary");
            }
            other => panic!("expected a temporary refusal, got {other:?}"),
        }

        // A server that offers no AUTH LOGIN is refused before a credential is even sent.
        let mut server = FakeSmtp::new("me@example.com", "s3cret");
        server.offer_auth = false;
        let mut smtp = Smtp::new("client", "me@example.com", Secret::new("s3cret"), &from, &verified, &composed);
        let events = submit(&mut smtp, &mut server);
        match events.iter().find(|event| matches!(event, Event::Refused { .. })) {
            Some(Event::Refused { code, detail, .. }) => {
                assert_eq!(*code, "email_smtp_no_auth");
                assert!(detail.contains("AUTH LOGIN"), "{detail}");
            }
            other => panic!("expected a no-auth refusal, got {other:?}"),
        }
        assert!(!server.commands.iter().any(|command| command == "AUTH LOGIN"));
    }

    #[test]
    fn a_body_line_that_is_only_a_dot_survives_the_data_phase() {
        // The body is base64, so the wire never carries a literal dot line from the text; the phase's
        // own terminator is what matters, and the message has to come out of it exactly as composed.
        let from = Mailbox::parse("me@example.com").unwrap();
        let verified = verified(&["ana@example.com"], "s", "linha um\n.\n.doisfim");
        let composed = compose(&from, &verified, "d", 0);
        let mut smtp = Smtp::new("client", "me@example.com", Secret::new("s3cret"), &from, &verified, &composed);
        let mut server = FakeSmtp::new("me@example.com", "s3cret");
        let events = submit(&mut smtp, &mut server);
        assert!(events.iter().any(|event| matches!(event, Event::Sent { .. })), "{events:?}");
        assert_eq!(server.data, composed.bytes, "the data phase delivered the composed message, unstuffed");
        // And the text is what the caller asked for, visible through the base64.
        let text = String::from_utf8(server.data).unwrap();
        let encoded = text.split("\r\n\r\n").nth(1).unwrap_or("").replace("\r\n", "");
        let decoded = String::from_utf8(base64::engine::general_purpose::STANDARD.decode(encoded.trim()).unwrap_or_default()).unwrap_or_default();
        assert_eq!(decoded, "linha um\n.\n.doisfim");
    }

    #[test]
    fn dot_stuffing_only_touches_the_start_of_a_line() {
        assert_eq!(dot_stuff(b"a.b\r\n.c\r\n"), b"a.b\r\n..c\r\n".to_vec());
        assert_eq!(dot_stuff(b".\r\n"), b"..\r\n".to_vec());
        assert_eq!(dot_stuff(b"nada"), b"nada".to_vec());
    }

    #[test]
    fn an_attachment_rides_inside_the_data_and_the_message_id_is_the_composed_one() {
        let from = Mailbox::parse("me@example.com").unwrap();
        let mut verified = verified(&["ana@example.com"], "Fatura", "Segue.");
        verified.attachments.push(Attachment { filename: "fatura.txt".into(), mime: "text/plain".into(), bytes: b"fatura 42".to_vec() });
        let composed = compose(&from, &verified, "d", 0);
        let mut smtp = Smtp::new("client", "me@example.com", Secret::new("s3cret"), &from, &verified, &composed);
        let mut server = FakeSmtp::new("me@example.com", "s3cret");
        let events = submit(&mut smtp, &mut server);
        assert!(events.iter().any(|event| matches!(event, Event::Sent { message_id, .. } if *message_id == composed.message_id)));
        let text = String::from_utf8(server.data).unwrap();
        assert!(text.contains("Content-Disposition: attachment; filename=\"fatura.txt\""));
        assert!(!text.contains("fatura 42"), "the attachment is base64 inside the message, not plain");
    }
}
