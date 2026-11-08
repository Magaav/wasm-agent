//! Audit lines: one per attempt, with no message text, no capability arguments and no secrets.
//!
//! The *line* is the rule and lives here, because two builds must produce the same bytes for the same
//! event: the node writes it to stderr and `<state>/audit/mesh.jsonl` (`wa_mesh::audit`), and the
//! `wa:mesh` guest renders it for the node when `WA_MESH_COMPONENT=1`. A line is enough to answer "who
//! called whom, what was decided, and how it ended" without a transcript of the work, which is what
//! `docs/MESH.md` §6 promises.
//!
//! What is not here: the sinks. A file, a rotation and a stderr handle are the node's business; a
//! component is handed an event and answers one line.
/// One mesh event. `kind` is `call` (outbound), `recv` (inbound) or `reply` (what was answered).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    pub kind: &'static str,
    /// Eight characters of an id is enough to follow one call and short enough to read.
    pub from: String,
    pub to: String,
    pub from_level: Option<u8>,
    pub to_level: Option<u8>,
    pub verb: String,
    pub decision: &'static str,
    pub reason: String,
    /// `direct:lan`, `direct:public`, `none`.
    pub transport: String,
    pub class: String,
    pub ok: bool,
    pub status: Option<u16>,
    pub ms: u64,
    pub attempt: u32,
}

impl Event {
    pub fn new(kind: &'static str, from: &str, to: &str) -> Event {
        Event {
            kind,
            from: short(from),
            to: short(to),
            from_level: None,
            to_level: None,
            verb: String::new(),
            decision: "deny",
            reason: String::new(),
            transport: "none".into(),
            class: String::new(),
            ok: false,
            status: None,
            ms: 0,
            attempt: 0,
        }
    }

    pub fn levels(mut self, from: Option<u8>, to: Option<u8>) -> Event {
        self.from_level = from;
        self.to_level = to;
        self
    }

    pub fn verb(mut self, verb: &str) -> Event {
        self.verb = verb.to_string();
        self
    }

    pub fn verdict(mut self, decision: &str, reason: &str) -> Event {
        self.decision = if decision == "allow" { "allow" } else { "deny" };
        self.reason = reason.to_string();
        self
    }

    pub fn transport(mut self, transport: &str, class: &str) -> Event {
        self.transport = transport.to_string();
        self.class = class.to_string();
        self
    }

    pub fn outcome(mut self, ok: bool, status: Option<u16>, ms: u64, attempt: u32) -> Event {
        self.ok = ok;
        self.status = status;
        self.ms = ms;
        self.attempt = attempt;
        self
    }

    /// The single writer of the line format, so stderr, the file, the guest and the tests cannot drift.
    pub fn render(&self) -> String {
        let mut line = format!("mesh {} from={} to={}", self.kind, self.from, self.to);
        if let (Some(from_level), Some(to_level)) = (self.from_level, self.to_level) {
            line.push_str(&format!(" levels={from_level}->{to_level}"));
        }
        if !self.verb.is_empty() {
            line.push_str(&format!(" verb={}", self.verb));
        }
        line.push_str(&format!(" decision={} reason={}", self.decision, self.reason));
        line.push_str(&format!(" transport={}", self.transport));
        if !self.class.is_empty() {
            line.push_str(&format!(" addr_class={}", self.class));
        }
        line.push_str(&format!(" ok={}", self.ok));
        if let Some(status) = self.status {
            line.push_str(&format!(" status={status}"));
        }
        line.push_str(&format!(" ms={} attempt={}", self.ms, self.attempt));
        line
    }
}

pub fn short(id: &str) -> String {
    id.chars().take(8).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_says_who_what_and_how_it_ended_without_the_work() {
        let event = Event::new("call", "8c11f0a2deadbeef", "3f2a91cdcafebabe")
            .levels(Some(0), Some(1))
            .verb("control")
            .verdict("allow", "hierarchy_allowed")
            .transport("direct:lan", "private")
            .outcome(true, Some(200), 41, 1);
        assert_eq!(
            event.render(),
            "mesh call from=8c11f0a2 to=3f2a91cd levels=0->1 verb=control decision=allow \
             reason=hierarchy_allowed transport=direct:lan addr_class=private ok=true status=200 ms=41 attempt=1"
        );
        let denied = Event::new("call", "aa", "bb")
            .verb("control")
            .verdict("deny", "hierarchy_denied")
            .outcome(false, None, 0, 0);
        let line = denied.render();
        assert!(line.contains("decision=deny reason=hierarchy_denied"));
        assert!(!line.contains("status="), "a denial that never went to the network has no status");
    }
}
