//! Audit lines: one per attempt, on stderr and (when the host names a file) appended to it.
//!
//! No message text, no capability arguments, no secrets — ids, levels, verbs, verdicts, the reason,
//! the address class and the duration. A line is enough to answer "who called whom, what was decided,
//! and how it ended" without a transcript of the work, which is what `docs/MESH.md` §6 promises.
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

pub trait Sink: Send + Sync {
    fn write(&self, line: &str);
}

/// The default: the same channel the relay and the rendezvous client log to, so an operator who is
/// already watching a node's stderr sees the mesh.
pub struct StderrSink;

impl Sink for StderrSink {
    fn write(&self, line: &str) {
        eprintln!("{line}");
    }
}

/// Append-only file with one backup generation, the shape `rust/wa-grant-policy`'s audit sink uses:
/// an audit trail that can fill a disk is an audit trail that can stop a node.
pub struct FileSink {
    path: PathBuf,
    limit: u64,
    lock: Mutex<()>,
}

impl FileSink {
    pub fn new(path: PathBuf, limit: u64) -> FileSink {
        FileSink { path, limit, lock: Mutex::new(()) }
    }

    fn append(&self, line: &str) {
        let _guard = self.lock.lock();
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(metadata) = std::fs::metadata(&self.path) {
            if self.limit > 0 && metadata.len() >= self.limit {
                let backup = self.path.with_extension("jsonl.1");
                let _ = std::fs::rename(&self.path, backup);
            }
        }
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&self.path) {
            let _ = writeln!(file, "{line}");
        }
    }
}

impl Sink for FileSink {
    fn write(&self, line: &str) {
        self.append(line);
    }
}

/// Both, in the order an operator reads them.
pub struct Tee {
    sinks: Vec<Box<dyn Sink>>,
}

impl Tee {
    pub fn new(sinks: Vec<Box<dyn Sink>>) -> Tee {
        Tee { sinks }
    }
}

impl Sink for Tee {
    fn write(&self, line: &str) {
        for sink in &self.sinks {
            sink.write(line);
        }
    }
}

/// A sink that keeps the lines it was given, for tests that assert on what was recorded.
pub struct MemorySink {
    lines: Mutex<Vec<String>>,
}

impl Default for MemorySink {
    fn default() -> Self {
        MemorySink { lines: Mutex::new(Vec::new()) }
    }
}

impl MemorySink {
    pub fn new() -> MemorySink {
        MemorySink::default()
    }

    pub fn lines(&self) -> Vec<String> {
        self.lines.lock().map(|lines| lines.clone()).unwrap_or_default()
    }
}

impl Sink for MemorySink {
    fn write(&self, line: &str) {
        if let Ok(mut lines) = self.lines.lock() {
            lines.push(line.to_string());
        }
    }
}

/// One mesh event. `kind` is `call` (outbound), `recv` (inbound) or `reply` (what was answered).
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

    /// The single writer of the line format, so stderr, the file and the tests cannot drift.
    pub fn render(&self) -> String {
        let mut line = format!(
            "mesh {} from={} to={}",
            self.kind, self.from, self.to
        );
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

    pub fn emit(&self, sink: &dyn Sink) {
        sink.write(&self.render());
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

    #[test]
    fn the_memory_sink_keeps_what_was_written_and_a_file_sink_rotates_once() {
        let sink = MemorySink::new();
        Event::new("recv", "aa", "bb").emit(&sink);
        assert_eq!(sink.lines().len(), 1);
        assert!(sink.lines()[0].starts_with("mesh recv from=aa to=bb"));

        let directory = std::env::temp_dir().join(format!("wa-mesh-audit-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        let path = directory.join("audit").join("mesh.jsonl");
        let file = FileSink::new(path.clone(), 200);
        for _ in 0..10 {
            Event::new("call", "aaaaaaaaaa", "bbbbbbbbbb").emit(&file);
        }
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("mesh call from=aaaaaaaa to=bbbbbbbb"));
        assert!(path.with_extension("jsonl.1").exists(), "the previous generation is kept once");
        let _ = std::fs::remove_dir_all(&directory);
    }
}
