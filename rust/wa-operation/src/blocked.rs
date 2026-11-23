//! WHY A RUNNING OPERATION IS NOT MOVING, read from the kernel instead of guessed (item 1, 23/11).
//!
//! The measured complaint: a mission's suite runner queues behind another mission's
//! `~/Work/missions/.suite.lock` and the await answers a bare "still running" for 20-50 minutes, so the
//! worker spends its turns probing with `ps` to find out who holds the lock (ledger notes 0, 1, 3, 189,
//! 244, 264, 269). Nothing was wrong with the answer - the work really was running - it just did not say
//! WHAT it waited on.
//!
//! What the kernel knows, measured on this node (Linux, 23/11): a process parked in flock(2) sleeps in
//! `locks_lock_inode_wait` (that is /proc/<pid>/wchan, readable for a process of our own user and needing
//! no root); /proc/locks lists the wait as a row for that pid marked with `->`, under the lock id of the
//! row that owns it; the owning row names the holder's pid; the waiter's own open descriptors name the
//! file, because a lock is taken on an open descriptor. So the three facts a worker needed - the file,
//! the holder's pid and command, and how long it has been held - are all readable, and none of them is
//! inferred.
//!
//! Deliberately NOT claimed: how long the HOLDER has held the lock. The kernel does not publish that
//! instant, and the only related fact is when the holder process started, which is an upper bound (a
//! long-lived process that took the lock late is younger than its lock). It is reported as
//! `holder_started_ms` and the sentence says "since that process started", so a reader gets the number
//! it is actually looking at. A lock entry with no owning row in this namespace is answered with
//! `holder_pid: null` and a sentence that says the holder could not be named - the waiter is still named
//! exactly, because that part is known.

use serde_json::{json, Value};
#[cfg(unix)]
use std::fs;

/// One row of /proc/locks, parsed. Kept separate from the /proc read so the shape is pinned by a test
/// that needs no lock and no child (a fixture string is the whole input).
#[derive(Debug, Clone, PartialEq)]
pub struct LockRow {
    /// The lock's own id, as printed (`"21:"`), shared by the owning row and every waiting row.
    pub id: u64,
    /// True for a row that is WAITING (`->`), false for the row that owns the lock.
    pub waiting: bool,
    pub kind: String,
    pub read_write: String,
    pub pid: u32,
    /// Device and inode exactly as /proc/locks prints them (`%02x:%02x:%s`), so a caller can compare
    /// them with a file's own numbers without re-deriving the device encoding.
    pub device: String,
    pub inode: u64,
}

/// Parse one /proc/locks row. `None` for a line this code does not understand, so an unfamiliar kernel
/// row is skipped rather than misread.
pub fn parse_lock_row(line: &str) -> Option<LockRow> {
    let mut fields = line.split_whitespace();
    let id = fields.next()?.trim_end_matches(':').parse().ok()?;
    let mut rest: Vec<&str> = fields.collect();
    let waiting = rest.first() == Some(&"->");
    if waiting {
        rest.remove(0);
    }
    // kind, "ADVISORY"|"MANDATORY", "READ"|"WRITE"|"RW", pid, device:inode, start, end
    if rest.len() < 6 {
        return None;
    }
    let pid = rest[3].parse().ok()?;
    // The field is device:inode, and the DEVICE ITSELF has a colon in it (\`00:38:7671677\`), so the split
    // is from the right. Splitting from the left read the inode as \`1e:12246\` and dropped every row.
    let (device, inode) = rest[4].rsplit_once(':')?;
    Some(LockRow {
        id,
        waiting,
        kind: rest[0].to_string(),
        read_write: rest[2].to_string(),
        pid,
        device: device.to_string(),
        inode: inode.parse().ok()?,
    })
}

/// Every parsed row of a /proc/locks body.
pub fn parse_locks(text: &str) -> Vec<LockRow> {
    text.lines().filter_map(parse_lock_row).collect()
}

/// The lock one pid is waiting on, with its holder and the holder's row, from parsed rows.
///
/// `None` when this pid is not waiting for a lock at all, which is the common case and must stay cheap
/// in what it claims: no row, no sentence.
pub fn waiter_view(rows: &[LockRow], pid: u32) -> Option<Value> {
    let waiting = rows.iter().find(|r| r.waiting && r.pid == pid)?;
    // Who owns it: the row with the same id that is NOT waiting. A kernel lock id is per-file-system and
    // reused over time, so the id is the only join key available and the owning row is printed with it.
    let holder = rows.iter().find(|r| !r.waiting && r.id == waiting.id);
    // Queue position: how many rows with this id wait BEFORE this one. 1 means "next", not "first".
    let position = rows
        .iter()
        .filter(|r| r.waiting && r.id == waiting.id && r.pid != pid)
        .count()
        + 1;
    let mut view = json!({
        "kind": "file_lock",
        "lock_inode": waiting.inode,
        "lock_device": waiting.device,
        "lock_mode": format!("{} {}", waiting.kind, waiting.read_write),
        "waiting_pid": pid,
        "queue_position": position,
        "holder_pid": holder.map(|r| json!(r.pid)).unwrap_or(Value::Null),
    });
    if let Some(holder) = holder {
        view["holder_pid"] = json!(holder.pid);
    }
    Some(view)
}

/// The sentence: the file, the holder's pid and command, and how long the lock has been held.
///
/// One function for every caller (the operation's state, the suite runner's log) so the wording cannot
/// drift between the two places a worker reads it.
pub fn lock_wait_note(view: &Value) -> String {
    let path = view["lock_path"].as_str().unwrap_or("");
    let mode = view["lock_mode"].as_str().unwrap_or("lock");
    let who = match (view["holder_pid"].as_u64(), view["holder_command"].as_str()) {
        (Some(pid), Some(command)) if !command.is_empty() => format!("pid {pid} ({command})"),
        (Some(pid), _) => format!("pid {pid}"),
        _ => "a process this node cannot name".to_string(),
    };
    let held = match view["holder_started_ms"].as_u64() {
        Some(ms) => format!(
            "; that process started {} ago, so the lock has been held at most that long",
            duration_text(ms)
        ),
        None => String::new(),
    };
    let place = match view["queue_position"].as_u64() {
        Some(n) if n > 1 => format!(" (this waiter is {n} in the queue)"),
        _ => String::new(),
    };
    let file = if path.is_empty() { "a file lock" } else { path };
    format!("waiting on a file lock: {file} ({mode}) is held by {who}{held}{place}")
}

/// `8m 12s`, `1h 4m`, `900ms` - the shape every log line here uses.
pub fn duration_text(ms: u64) -> String {
    let seconds = ms / 1000;
    match seconds {
        0 => format!("{ms}ms"),
        s if s < 60 => format!("{s}s"),
        s if s < 3600 => format!("{}m {}s", s / 60, s % 60),
        s => format!("{}h {}m", s / 3600, (s % 3600) / 60),
    }
}

/// Everything this node can say about a process tree parked on a file lock, or `None`.
///
/// `root` is the operation's own shell; the wait is looked for in it AND in its descendants, because a
/// runner's lock wait happens in a child (`flock -o <file> <command>` is a process of its own).
#[cfg(unix)]
pub fn lock_wait(root: u32) -> Option<Value> {
    let rows = parse_locks(&fs::read_to_string("/proc/locks").ok()?);
    for pid in tree(root) {
        // MEASURED (23/11, this node): flock(2) parks a task in `locks_lock_inode_wait`. Nothing else is
        // read as a lock wait - a wrong cause is worse than no cause, and this one is a fact from wchan.
        let Ok(wchan) = fs::read_to_string(format!("/proc/{pid}/wchan")) else { continue };
        if !wchan.trim().ends_with("lock_inode_wait") {
            continue;
        }
        let Some(mut view) = waiter_view(&rows, pid) else { continue };
        view["waiting_command"] = json!(command_of(pid));
        if let Some(holder) = view["holder_pid"].as_u64() {
            view["holder_command"] = json!(command_of(holder as u32));
            view["holder_started_ms"] = json!(process_age_ms(holder as u32));
        }
        // The lock FILE: a lock is taken on an open descriptor, so the waiter holds the file open. The
        // waiter's own descriptors are read first; the holder's are the fallback for a wait whose file
        // was closed in the waiter (a kernel that keeps the lock on the holder's descriptor only).
        let inode = view["lock_inode"].as_u64().unwrap_or(0);
        let path = descriptor_path(pid, inode)
            .or_else(|| view["holder_pid"].as_u64().and_then(|h| descriptor_path(h as u32, inode)));
        view["lock_path"] = json!(path);
        view["note"] = json!(lock_wait_note(&view));
        return Some(view);
    }
    None
}

/// The pid and all its descendants, as /proc currently sees them. Bounded by the process table.
#[cfg(unix)]
pub fn tree(root: u32) -> Vec<u32> {
    let Ok(entries) = fs::read_dir("/proc") else { return Vec::new() };
    let mut children: std::collections::HashMap<u32, Vec<u32>> = std::collections::HashMap::new();
    for entry in entries.flatten() {
        let Some(pid) = entry.file_name().to_str().and_then(|name| name.parse::<u32>().ok()) else {
            continue;
        };
        let Some(parent) = parent_of(pid) else { continue };
        children.entry(parent).or_default().push(pid);
    }
    // Breadth first from the root, so the operation's own shell is looked at first.
    let mut found = vec![root];
    let mut index = 0;
    while index < found.len() {
        if let Some(kids) = children.get(&found[index]) {
            for kid in kids {
                if !found.contains(kid) {
                    found.push(*kid);
                }
            }
        }
        index += 1;
    }
    found
}

#[cfg(unix)]
fn parent_of(pid: u32) -> Option<u32> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // `comm` may contain spaces and parentheses, so the fields are counted from the LAST ')': after it
    // comes state, then ppid.
    let tail = &stat[stat.rfind(')')? + 1..];
    tail.split_whitespace().nth(1)?.parse().ok()
}

/// The command line of a pid, trimmed to what a log line can carry. Empty when it cannot be read.
#[cfg(unix)]
fn command_of(pid: u32) -> String {
    let Ok(raw) = fs::read(format!("/proc/{pid}/cmdline")) else { return String::new() };
    let text = raw
        .split(|byte| *byte == 0)
        .filter(|part| !part.is_empty())
        .map(|part| String::from_utf8_lossy(part).to_string())
        .collect::<Vec<String>>()
        .join(" ");
    let trimmed = text.trim();
    if trimmed.chars().count() <= 160 {
        return trimmed.to_string();
    }
    let mut cut: String = trimmed.chars().take(157).collect();
    cut.push_str("...");
    cut
}

/// How long ago a process started, from /proc (btime + its starttime), in milliseconds.
#[cfg(unix)]
fn process_age_ms(pid: u32) -> Option<u64> {
    let ticks_per_second = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    let ticks_per_second = if ticks_per_second > 0 { ticks_per_second as u64 } else { 100 };
    let boot = boot_epoch_seconds()?;
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let tail = &stat[stat.rfind(')')? + 1..];
    // After `)` come state (1) and ppid..starttime: starttime is field 22 of the whole line, which is this
    // tail's index 19 (state is 1, so field n of the line is index n-3 of the tail).
    let start_ticks: u64 = tail.split_whitespace().nth(19)?.parse().ok()?;
    let started = boot.checked_add(start_ticks / ticks_per_second)?;
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).ok()?.as_secs();
    Some(now.saturating_sub(started) * 1000)
}

#[cfg(unix)]
fn boot_epoch_seconds() -> Option<u64> {
    let stat = fs::read_to_string("/proc/stat").ok()?;
    for line in stat.lines() {
        if let Some(rest) = line.strip_prefix("btime ") {
            return rest.trim().parse().ok();
        }
    }
    None
}

/// Which open file of `pid` is the lock's inode, as a path.
///
/// The INODE is the key and the device is deliberately not compared: measured on this node (23/11), a
/// file under ~/.wasm-agent reports `st_dev` 0x36 while /proc/locks prints the same file's device as
/// `00:1e` (the home is btrfs, and a subvolume's anonymous st_dev is not what the lock row carries), so
/// a device comparison would have refused to name a lock it had already found. The inode the kernel
/// prints IS the file's `st_ino`, and the candidates are only this process's own open files.
#[cfg(unix)]
fn descriptor_path(pid: u32, inode: u64) -> Option<String> {
    use std::os::unix::fs::MetadataExt;
    if inode == 0 {
        return None;
    }
    let entries = fs::read_dir(format!("/proc/{pid}/fd")).ok()?;
    for entry in entries.flatten() {
        let Ok(target) = fs::read_link(entry.path()) else { continue };
        let Ok(meta) = fs::metadata(&target) else { continue };
        if meta.ino() != inode {
            continue;
        }
        return Some(target.to_string_lossy().to_string());
    }
    None
}

#[cfg(not(unix))]
pub fn lock_wait(_root: u32) -> Option<Value> {
    None
}
