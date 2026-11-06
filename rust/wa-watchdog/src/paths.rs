//! Where the watchdog keeps its state, and how it writes it down.
//!
//! Everything is a file under one directory, because every reader of this state is a shell script or a
//! human: `<home>/current` names the binary that is running (a one-line answer to "what is on the port"),
//! `status.json` is the machine answer, `requests/` and `results/` are the swap protocol, and `bin/<sha12>/`
//! holds every binary ever swapped in so a rollback never has to rebuild one.
//!
//! Writes are atomic (write beside, rename over) for the same reason `scripts/upgrade.sh` renames: a crash
//! between two writes must not leave a half-written record that a later reader believes.

use std::io;
use std::path::{Path, PathBuf};

use crate::json;
use crate::state::{ActiveKernel, Status};

#[derive(Debug, Clone)]
pub struct Home {
    root: PathBuf,
}

impl Home {
    /// `explicit` (a `--home` flag) wins, then `WA_WATCHDOG_HOME`, then the runtime home of the node:
    /// `<WASM_AGENT_HOME or ~/.wasm-agent>/watchdog`. The watchdog lives beside the node's own state so a
    /// backup of the home is a backup of what makes the node restartable.
    pub fn resolve(explicit: Option<PathBuf>) -> Result<Home, String> {
        if let Some(root) = explicit {
            return Ok(Home { root });
        }
        if let Some(root) = std::env::var_os("WA_WATCHDOG_HOME").filter(|value| !value.is_empty()) {
            return Ok(Home { root: PathBuf::from(root) });
        }
        let node_home = match std::env::var_os("WASM_AGENT_HOME").filter(|value| !value.is_empty()) {
            Some(home) => PathBuf::from(home),
            None => {
                let base = std::env::var_os("HOME")
                    .or_else(|| std::env::var_os("USERPROFILE"))
                    .ok_or_else(|| "cannot resolve a home directory: set WA_WATCHDOG_HOME".to_string())?;
                PathBuf::from(base).join(".wasm-agent")
            }
        };
        Ok(Home { root: node_home.join("watchdog") })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn ensure(&self) -> io::Result<()> {
        for dir in [self.root.clone(), self.bin_dir(), self.requests_dir(), self.results_dir(), self.logs_dir(), self.work_dir()] {
            std::fs::create_dir_all(&dir)?;
        }
        Ok(())
    }

    pub fn config_path(&self) -> PathBuf {
        self.root.join("watchdog.conf")
    }
    pub fn bin_dir(&self) -> PathBuf {
        self.root.join("bin")
    }
    pub fn requests_dir(&self) -> PathBuf {
        self.root.join("requests")
    }
    pub fn results_dir(&self) -> PathBuf {
        self.root.join("results")
    }
    pub fn logs_dir(&self) -> PathBuf {
        self.root.join("logs")
    }
    pub fn work_dir(&self) -> PathBuf {
        self.root.join("work")
    }
    pub fn status_path(&self) -> PathBuf {
        self.root.join("status.json")
    }
    /// The human/script answer: the path of the binary that is running, one line.
    pub fn current_path(&self) -> PathBuf {
        self.root.join("current")
    }
    /// The machine answer beside it: binary, its pin, and the arguments as written (placeholders intact).
    pub fn current_json_path(&self) -> PathBuf {
        self.root.join("current.json")
    }
    pub fn supervisor_pid_path(&self) -> PathBuf {
        self.root.join("supervisor.pid")
    }
    pub fn kernel_pid_path(&self) -> PathBuf {
        self.root.join("kernel.pid")
    }
    pub fn stop_flag_path(&self) -> PathBuf {
        self.root.join("stop")
    }
    pub fn log_path(&self, name: &str) -> PathBuf {
        self.logs_dir().join(format!("{name}.log"))
    }

    pub fn write_atomic(&self, path: &Path, text: &str) -> io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let temporary = path.with_extension(format!("tmp{}", std::process::id()));
        std::fs::write(&temporary, text)?;
        // `rename` replaces the destination on both Unix and Windows (MoveFileEx with REPLACE_EXISTING).
        std::fs::rename(&temporary, path).inspect_err(|_| {
            let _ = std::fs::remove_file(&temporary);
        })
    }

    pub fn write_status(&self, status: &Status) -> io::Result<()> {
        self.write_atomic(&self.status_path(), &(status.to_json() + "\n"))
    }

    pub fn read_status_text(&self) -> Option<String> {
        std::fs::read_to_string(self.status_path()).ok()
    }

    /// The active kernel, from `current.json`. Falls back to `current` (a bare path) so a hand-written or
    /// older record still starts.
    pub fn read_current(&self) -> Option<ActiveKernel> {
        if let Ok(text) = std::fs::read_to_string(self.current_json_path()) {
            if let Some(active) = ActiveKernel::from_json(&text) {
                return Some(active);
            }
        }
        let path = std::fs::read_to_string(self.current_path()).ok()?;
        let path = path.trim();
        if path.is_empty() {
            return None;
        }
        Some(ActiveKernel { binary: PathBuf::from(path), sha256: None, args: Vec::new() })
    }

    pub fn write_current(&self, active: &ActiveKernel) -> io::Result<()> {
        self.write_atomic(&self.current_json_path(), &(active.to_json() + "\n"))?;
        self.write_atomic(&self.current_path(), &(active.binary.display().to_string() + "\n"))
    }

    pub fn write_pid(&self, path: &Path, pid: u32) -> io::Result<()> {
        self.write_atomic(path, &format!("{pid}\n"))
    }

    /// True when `stop` asked the supervisor to end. The flag is removed by the supervisor that acts on it,
    /// so "the request still exists" means "nobody has acted on it yet".
    pub fn stop_requested(&self) -> bool {
        self.stop_flag_path().exists()
    }

    /// The last `lines` lines of a log, for a refusal message. Never the whole file, never message text.
    pub fn tail(path: &Path, lines: usize) -> String {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(_) => return String::new(),
        };
        let collected: Vec<&str> = text.lines().collect();
        collected[collected.len().saturating_sub(lines)..].join("\n")
    }
}

/// One swap request on disk: what `wa-watchdog swap` verified and stored, and what the supervisor consumes.
#[derive(Debug, Clone, PartialEq)]
pub struct SwapRequest {
    pub id: String,
    pub binary: PathBuf,
    pub sha256: String,
    /// The argument list for the NEW binary, as written (placeholders intact).
    pub args: Vec<String>,
    pub at_ms: u64,
}

impl SwapRequest {
    pub fn to_json(&self) -> String {
        let args = JsonArray(&self.args);
        json::object(&[
            ("id", self.id.clone().into()),
            ("binary", self.binary.clone().into()),
            ("sha256", self.sha256.clone().into()),
            ("args", json::Json::Raw(args.render())),
            ("at_ms", self.at_ms.into()),
        ])
    }

    pub fn from_json(text: &str) -> Option<SwapRequest> {
        Some(SwapRequest {
            id: json::field_str(text, "id")?,
            binary: PathBuf::from(json::field_str(text, "binary")?),
            sha256: json::field_str(text, "sha256")?,
            args: args_from_json(text),
            at_ms: json::field_u64(text, "at_ms").unwrap_or(0),
        })
    }
}

/// A JSON array of strings, which `json::object` does not otherwise carry.
pub struct JsonArray<'a>(pub &'a [String]);

impl JsonArray<'_> {
    pub fn render(&self) -> String {
        format!("[{}]", self.0.iter().map(|item| json::quote(item)).collect::<Vec<_>>().join(","))
    }
}

/// The strings of a JSON array of strings (the `args` field of a request or an active-kernel record).
pub fn args_from_json(text: &str) -> Vec<String> {
    let raw = match json::field(text, "args") {
        Some(raw) => raw.trim(),
        None => return Vec::new(),
    };
    let inner = raw.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')).unwrap_or("");
    let mut out = Vec::new();
    let mut index = 0usize;
    let bytes = inner.as_bytes();
    while index < bytes.len() {
        match bytes[index] {
            b'"' => {
                let start = index;
                index += 1;
                while index < bytes.len() {
                    match bytes[index] {
                        b'\\' => index += 2,
                        b'"' => {
                            index += 1;
                            break;
                        }
                        _ => index += 1,
                    }
                }
                if let Some(arg) = json::unquote(&inner[start..index]) {
                    out.push(arg);
                }
            }
            _ => index += 1,
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("wa-watchdog-paths-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("scratch dir");
        root
    }

    #[test]
    fn current_round_trips_and_stays_readable() {
        let root = scratch("current");
        let home = Home { root: root.clone() };
        let active = ActiveKernel {
            binary: PathBuf::from("/opt/wa/bin/wa-abc/wa"),
            sha256: Some("ab".repeat(32)),
            args: vec!["serve".into(), "--port".into(), "{port}".into(), "a path with spaces".into()],
        };
        home.write_current(&active).expect("write current");
        assert_eq!(home.read_current(), Some(active));
        // The one-line file is what a shell script greps.
        let one_line = std::fs::read_to_string(home.current_path()).expect("read current");
        assert_eq!(one_line.trim(), "/opt/wa/bin/wa-abc/wa");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_bare_current_file_still_starts_a_kernel() {
        let root = scratch("bare");
        let home = Home { root: root.clone() };
        std::fs::write(home.current_path(), "/opt/wa/wa\n").expect("write bare current");
        let active = home.read_current().expect("a bare path is enough");
        assert_eq!(active.binary, PathBuf::from("/opt/wa/wa"));
        assert_eq!(active.args, Vec::<String>::new());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_swap_request_round_trips() {
        let request = SwapRequest {
            id: "swap-1".into(),
            binary: PathBuf::from("/opt/wa/bin/abc/wa"),
            sha256: "cd".repeat(32),
            args: vec!["serve".into(), "--port".into(), "{port}".into(), "--x".into(), "a \"quoted\" arg".into()],
            at_ms: 17,
        };
        assert_eq!(SwapRequest::from_json(&request.to_json()), Some(request));
    }
}
