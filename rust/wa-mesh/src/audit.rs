//! Audit sinks: where a line goes (stderr, a rotated file, both, a test's memory).
//!
//! The *line* is `wa-mesh-core::audit`'s, because the `wa:mesh` guest renders it too and the two must
//! agree to the character (`docs/MESH.md` §6, and `scripts/test-mesh-component.sh` compares them). This
//! file is the node's half: the file, its one-generation rotation, and the tee an operator's stderr and
//! `mesh.jsonl` share.
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

pub use wa_mesh_core::audit::{short, Event};

pub trait Sink: Send + Sync {
    fn write(&self, line: &str);
}

/// `Event::emit(&sink)` in the shape every call site already uses. The line is the renderer's, so a
/// component that renders it (or that fails to) cannot change the format.
pub trait Emit {
    fn emit(&self, sink: &dyn Sink);
}

impl Emit for Event {
    fn emit(&self, sink: &dyn Sink) {
        sink.write(&crate::seam::render_audit(self));
    }
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

#[cfg(test)]
mod tests {
    use super::*;

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
