//! One root, one `wa clean`, one disk cap (`docs/ONEROOT.md`).
//!
//! WHY. Measured 12/11 on wa-desktop after one morning of agents: ~100 GB, of which worktrees were
//! ~45 GB (`~/wt-*`, 42 of them, scattered beside the home) and per-mission build dirs ~25 GB
//! (`rust/target-*`), plus 3.3 GB of `/tmp` and 0.8 GB of mission logs - while the node's own state
//! (`~/.wasm-agent`) was 0.4 GB. Nothing cleaned up after the agents: every mission created a tree and
//! a target, and no command existed that could say what was reclaimable, let alone reclaim it. The same
//! day `/tmp` was 98 % full on `work` and broke deploys, `nextcloud` held 152 orphaned docker volumes,
//! and `openclaw` was at 99 %.
//!
//! The operator's decision (KISS / Da Vinci) is three things, and this module is all three:
//!
//! 1. **One root.** Everything an agent creates lives under [`wa_host_support::paths::state_root`] -
//!    the state root the node already had. That is a layout inside one directory (`tmp/`,
//!    `worktrees/`, `build/`, `cache/`, `logs/`, `operations/`), never a second root concept.
//! 2. **One command.** `wa clean` deletes finished worktrees (their branch landed), operations, logs
//!    and temp files older than N days, honours pins, and refuses to touch anything outside the root.
//! 3. **One cap.** Past `cap_percent` (default 85) of the filesystem, the node runs the same clean
//!    before it starts new heavy work and refuses by name (`disk_cap`) when cleaning cannot help.
//!
//! WHAT THIS DELIBERATELY DOES NOT DO. It never moves or deletes the scattered directories that
//! predate the root (`~/wt-*`, `rust/target-*` beside a checkout, `/tmp/wa-*`): `wa clean --dry-run`
//! reports them and the operator decides. It never removes a worktree whose work is not landed, or
//! that is dirty, or that is detached (a deploy/rollback pin), or that anything pins. It never deletes
//! the live install, the ledger, memory, sessions, components or the sentinel queue - they are not
//! candidates at all, and they are also on a named protected list.
use serde_json::{json, Value};
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use wa_host_support::lua::{arg_string, LuaState};

/// Retention default: operations, logs and temp files older than this are deletable.
pub const DEFAULT_DAYS: u64 = 7;
/// The cap default: the fraction of the root's filesystem at which new heavy work is refused.
pub const DEFAULT_CAP_PERCENT: f64 = 85.0;
/// A group reports at most this many named rows; the totals always cover every entry.
const ROW_LIMIT: usize = 20;

// ---------------------------------------------------------------------------------------------------
// the layout
// ---------------------------------------------------------------------------------------------------

/// The directory names `wa clean` knows about. Anything else inside the root is left alone: a cleaner
/// that walks the whole root would eventually delete something nobody classified.
pub const RETENTION_GROUPS: [&str; 4] = ["operations", "logs", "tmp", "build"];

/// Names inside the root that are state, never a candidate. The groups above cannot reach them, and
/// this list is the second, explicit answer to "is it safe": a name here is refused even if a future
/// group's glob would match it.
pub const PROTECTED: [&str; 14] = [
    "memory.db",
    "graph.db",
    "rendezvous.db",
    "components",
    "releases",
    "archive",
    "sentinel",
    "watchdog",
    "commands",
    "bin",
    "node",
    "installed.txt",
    "deploy-result.json",
    "env",
];

fn now_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn cap_percent() -> f64 {
    std::env::var("WASM_AGENT_DISK_CAP")
        .ok()
        .and_then(|text| text.trim().parse::<f64>().ok())
        .filter(|percent| (1.0..=100.0).contains(percent))
        .unwrap_or(DEFAULT_CAP_PERCENT)
}

fn retention_days() -> u64 {
    std::env::var("WASM_AGENT_CLEAN_DAYS")
        .ok()
        .and_then(|text| text.trim().parse::<u64>().ok())
        .filter(|days| *days > 0)
        .unwrap_or(DEFAULT_DAYS)
}

// ---------------------------------------------------------------------------------------------------
// the guard: nothing outside the root, ever
// ---------------------------------------------------------------------------------------------------

/// Refuse a candidate that is not provably inside `root`.
///
/// Three separate refusals, because they are three separate mistakes:
/// * a `..` component is refused *before* touching the filesystem: `root/tmp/../../../etc` is a path
///   that reads as inside the root and is not;
/// * a symlink is refused rather than followed: `root/tmp/x -> /etc` would otherwise delete the target
///   of the link (a `remove_dir_all` on a link removes the link, but a size walk, a `rm -rf` from a
///   shell, or a future caller is one mistake away from the target);
/// * the canonical path must still start with the canonical root, which catches a parent directory
///   that is itself a link out of the root.
///
/// The proof lives in `scripts/test-oneroot.lua`: a symlink and a `..` path are both refused by name.
pub fn guard_inside(root: &Path, candidate: &Path) -> Result<PathBuf, String> {
    if candidate.components().any(|part| matches!(part, Component::ParentDir)) {
        return Err(format!("outside_root: {} names a `..` component", candidate.display()));
    }
    let root_canonical = std::fs::canonicalize(root)
        .map_err(|error| format!("root_unreadable: {}: {error}", root.display()))?;
    let meta = std::fs::symlink_metadata(candidate)
        .map_err(|error| format!("unreadable: {}: {error}", candidate.display()))?;
    if meta.file_type().is_symlink() {
        return Err(format!(
            "symlink_not_followed: {} is a link; a cleaner never follows one out of the root",
            candidate.display()
        ));
    }
    let canonical = std::fs::canonicalize(candidate)
        .map_err(|error| format!("unreadable: {}: {error}", candidate.display()))?;
    if canonical == root_canonical || !canonical.starts_with(&root_canonical) {
        return Err(format!(
            "outside_root: {} resolves to {} which is not under {}",
            candidate.display(),
            canonical.display(),
            root_canonical.display()
        ));
    }
    // A directory reached *through* a link is still outside the root in the only sense that matters:
    // its canonical form decides, and that is exactly what `canonical` is above. Belt and braces: the
    // parent chain of the *unresolved* path must not contain a link either.
    let mut walked = candidate.to_path_buf();
    while let Some(parent) = walked.parent() {
        if parent == root || parent.as_os_str().is_empty() {
            break;
        }
        if let Ok(meta) = std::fs::symlink_metadata(parent) {
            if meta.file_type().is_symlink() {
                return Err(format!(
                    "symlink_not_followed: {} is reached through the link {}",
                    candidate.display(),
                    parent.display()
                ));
            }
        }
        walked = parent.to_path_buf();
    }
    Ok(canonical)
}

// ---------------------------------------------------------------------------------------------------
// measurement
// ---------------------------------------------------------------------------------------------------

#[derive(Clone, Copy, Debug)]
pub struct DiskUsage {
    pub total_bytes: u64,
    pub free_bytes: u64,
    pub used_percent: f64,
}

/// Free/total bytes of the filesystem `path` lives on. `None` when it cannot be measured - never a
/// made-up zero, because a zero that means unknown is the value a cap would refuse on.
#[cfg(unix)]
pub fn disk_usage(path: &Path) -> Option<DiskUsage> {
    use std::os::unix::ffi::OsStrExt;
    let c_path = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) } != 0 {
        return None;
    }
    let block = stat.f_frsize.max(1) as u64;
    let total = (stat.f_blocks as u64).saturating_mul(block);
    // `f_bavail` is what an unprivileged process may use, which is what a build needs.
    let free = (stat.f_bavail as u64).saturating_mul(block);
    if total == 0 {
        return None;
    }
    let used = total.saturating_sub(free);
    Some(DiskUsage { total_bytes: total, free_bytes: free, used_percent: 100.0 * used as f64 / total as f64 })
}

#[cfg(not(unix))]
pub fn disk_usage(_path: &Path) -> Option<DiskUsage> {
    // Windows has GetDiskFreeSpaceExW, which this crate does not link today. Reporting `None` (and a
    // named reason upward) is the honest answer: the cap cannot be enforced on a node that cannot
    // measure, and a cleaner must not pretend it did.
    None
}

/// Recursive size of one entry, never following a link. Returns `(bytes, files)`.
pub fn measure(path: &Path) -> (u64, u64) {
    let mut unlimited = u64::MAX;
    measure_budgeted(path, &mut unlimited).0
}

/// The same walk with a file budget, for the entries outside the root: a `--dry-run` that spends
/// minutes walking 70 GB of somebody else's scattered build dirs is a report nobody waits for. The
/// third value says whether the walk finished, so an incomplete number is never presented as exact.
fn measure_budgeted(path: &Path, budget: &mut u64) -> ((u64, u64), bool) {
    let meta = match std::fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(_) => return ((0, 0), true),
    };
    if meta.file_type().is_symlink() {
        return ((0, 1), true);
    }
    if meta.is_file() {
        return ((meta.len(), 1), true);
    }
    let (mut bytes, mut files, mut complete) = (0u64, 1u64, true);
    if let Ok(entries) = std::fs::read_dir(path) {
        for entry in entries.flatten() {
            if *budget == 0 {
                return ((bytes, files), false);
            }
            *budget = budget.saturating_sub(1);
            let ((child_bytes, child_files), child_complete) = measure_budgeted(&entry.path(), budget);
            bytes = bytes.saturating_add(child_bytes);
            files = files.saturating_add(child_files);
            complete = complete && child_complete;
        }
    }
    ((bytes, files), complete)
}

/// The scattered directories that PREDATE the root, reported and never touched.
///
/// The operator's rule is explicit: new things go to the new places, and what is already scattered
/// (`~/wt-*`, a `rust/target-*` beside a checkout, `/tmp/wa-*`) is **reported** by
/// `wa clean --dry-run` and decided by a human. Half of those trees are drafts that were never
/// committed, so a cleaner that "tidied" them would be the incident this whole change exists to
/// prevent, in the other direction.
///
/// The walk is budgeted: the point is a table an operator reads in one screen, not a measurement good
/// enough to delete from. An entry the budget stopped is marked `complete: false` and its size is a
/// floor, not a total.
pub fn outside(root: &Path) -> Value {
    // Two bounds, both named in the output: a file budget and a wall-clock deadline. A `--dry-run` that
    // spends minutes walking 70 GB of somebody else's scattered build dirs is a report nobody waits for,
    // and a number it did not finish measuring must never read as a total.
    const FILE_BUDGET: u64 = 400_000;
    const DEADLINE_SECS: u64 = 25;
    const ENTRY_LIMIT: usize = 200;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(DEADLINE_SECS);
    let mut budget = FILE_BUDGET;
    let mut rows: Vec<Value> = Vec::new();
    let home = root.parent().map(Path::to_path_buf).unwrap_or_else(|| root.to_path_buf());
    let matches = |name: &str| -> bool {
        (name.starts_with("wt-") || name.starts_with("target-") || name.starts_with("wa-gate-home-"))
            && name != ".wasm-agent"
    };
    let mut consider = |path: PathBuf, rows: &mut Vec<Value>, budget: &mut u64| {
        if rows.len() >= ENTRY_LIMIT {
            return;
        }
        if *budget == 0 || std::time::Instant::now() > deadline {
            rows.push(json!({
                "path": path.to_string_lossy(),
                "bytes": 0,
                "files": 0,
                "complete": false,
                "why": "not measured: the report is bounded; measure it directly (du -sh) if it matters",
            }));
            return;
        }
        let ((bytes, files), complete) = measure_budgeted(&path, budget);
        rows.push(json!({
            "path": path.to_string_lossy(),
            "bytes": bytes,
            "files": files,
            "complete": complete,
            "why": "outside the root: reported only, never moved or deleted automatically",
        }));
    };
    if let Ok(entries) = std::fs::read_dir(&home) {
        let mut children: Vec<PathBuf> = entries.flatten().map(|entry| entry.path()).collect();
        children.sort();
        for child in children {
            let name = child.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            if child.is_dir() && matches(&name) {
                consider(child.clone(), &mut rows, &mut budget);
            }
            // A checkout's own per-mission target dirs: `<tree>/rust/target-*`.
            let rust = child.join("rust");
            if rust.is_dir() {
                if let Ok(targets) = std::fs::read_dir(&rust) {
                    let mut found: Vec<PathBuf> = targets
                        .flatten()
                        .map(|entry| entry.path())
                        .filter(|path| {
                            path.is_dir()
                                && path
                                    .file_name()
                                    .and_then(|name| name.to_str())
                                    .map(|name| name.starts_with("target-") || name == "target")
                                    .unwrap_or(false)
                        })
                        .collect();
                    found.sort();
                    for path in found {
                        consider(path, &mut rows, &mut budget);
                    }
                }
            }
        }
    }
    // The OS temp dir: mission scratch that no root owns yet. Aggregated into ONE row per family,
    // because the operator decides about a family ("the wa-* scratch in /tmp"), not about each of 3533
    // entries - and a per-entry list would push the 21.7 GB target dirs off the screen.
    let temp = std::env::temp_dir();
    if let Ok(entries) = std::fs::read_dir(&temp) {
        let mut family = (0u64, 0u64, 0u64);
        let mut complete = true;
        let mut found: Vec<PathBuf> = entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .map(|name| name.starts_with("wa-"))
                    .unwrap_or(false)
            })
            .collect();
        found.sort();
        for path in found {
            if budget == 0 || std::time::Instant::now() > deadline {
                complete = false;
                family.0 += 1;
                continue;
            }
            let ((bytes, files), done) = measure_budgeted(&path, &mut budget);
            family = (family.0 + 1, family.1 + bytes, family.2 + files);
            complete = complete && done;
        }
        if family.0 > 0 {
            rows.push(json!({
                "path": temp.to_string_lossy(),
                "entries": family.0,
                "bytes": family.1,
                "files": family.2,
                "complete": complete,
                "why": "wa-* entries in the OS temp dir: reported only, never moved or deleted automatically",
            }));
        }
    }
    rows.sort_by(|left, right| right["bytes"].as_u64().cmp(&left["bytes"].as_u64()));
    let total: u64 = rows.iter().filter_map(|row| row["bytes"].as_u64()).sum();
    let complete = budget > 0 && rows.len() < ENTRY_LIMIT && std::time::Instant::now() <= deadline;
    json!({
        "note": "these predate the one root; `wa clean` reports them and never moves or deletes them - the operator decides. A worktree and the target dir inside it are counted twice here (once inside the tree, once on its own line), so the total is a shape, not an invoice",
        "root": root.to_string_lossy(),
        "scanned": [home.to_string_lossy(), temp.to_string_lossy()],
        "entries": rows.len(),
        "bytes": total,
        "complete": complete,
        "deadline_seconds": DEADLINE_SECS,
        "rows": rows,
    })
}

fn age_days(path: &Path, now: u64) -> f64 {
    let modified = std::fs::metadata(path).and_then(|meta| meta.modified()).ok();
    match modified.and_then(|time| time.duration_since(UNIX_EPOCH).ok()) {
        Some(stamp) => {
            let at = stamp.as_secs();
            if at >= now { 0.0 } else { (now - at) as f64 / 86_400.0 }
        }
        // A mtime we cannot read is a thing we cannot age: it is kept, and says so.
        None => -1.0,
    }
}

// ---------------------------------------------------------------------------------------------------
// pins
// ---------------------------------------------------------------------------------------------------

fn pins_file(root: &Path) -> PathBuf {
    root.join("clean").join("pins")
}

fn read_pins(root: &Path) -> Vec<PathBuf> {
    let mut pins = Vec::new();
    if let Ok(text) = std::fs::read_to_string(pins_file(root)) {
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let path = PathBuf::from(line);
            pins.push(if path.is_absolute() { path } else { root.join(path) });
        }
    }
    let text = std::fs::read_to_string(root.join("clean").join("pins")).unwrap_or_default();
    let _ = text;
    pins
}

fn write_pins(root: &Path, pins: &[PathBuf]) -> Result<(), String> {
    let file = pins_file(root);
    if let Some(parent) = file.parent() {
        std::fs::create_dir_all(parent).map_err(|error| format!("pins_dir_failed: {error}"))?;
    }
    let mut text = String::from(
        "# wa clean pins: one path per line, relative to the root or absolute. A pinned path is never\n\
         # deleted, and neither is anything inside it. Written by `wa clean --pin <path>`.\n",
    );
    for pin in pins {
        text.push_str(&pin.to_string_lossy());
        text.push('\n');
    }
    std::fs::write(&file, text).map_err(|error| format!("pins_write_failed: {error}"))
}

/// Is `path` pinned? A pin on a directory pins everything inside it, and a `.wa-pin` marker file in a
/// directory pins that directory *and everything inside it* (a marker travels with the tree it
/// protects, so a mission can protect its own work without editing a list outside it).
fn pinned(root: &Path, path: &Path, pins: &[PathBuf]) -> Option<String> {
    for pin in pins {
        let pin_text = pin.to_string_lossy().replace('\\', "/");
        let path_text = path.to_string_lossy().replace('\\', "/");
        if path_text == pin_text || path_text.starts_with(&format!("{pin_text}/")) {
            return Some(format!("pinned by {}", pin.display()));
        }
    }
    let mut walked = Some(path);
    while let Some(dir) = walked {
        let marker = dir.join(".wa-pin");
        if marker.is_file() {
            let why = std::fs::read_to_string(&marker).unwrap_or_default();
            let why = why.trim();
            return Some(if why.is_empty() {
                format!("pinned by {}", marker.display())
            } else {
                format!("pinned by {}: {why}", marker.display())
            });
        }
        if dir == root {
            break;
        }
        walked = dir.parent();
    }
    None
}

// ---------------------------------------------------------------------------------------------------
// git facts about a worktree
// ---------------------------------------------------------------------------------------------------

fn git(cwd: &Path, args: &[&str]) -> Option<String> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// The canonical checkout a linked worktree belongs to, from its own `.git` file.
fn canonical_of_worktree(path: &Path) -> Option<PathBuf> {
    let common = git(path, &["rev-parse", "--path-format=absolute", "--git-common-dir"])?;
    let common = PathBuf::from(common);
    if common.file_name().map(|name| name == ".git").unwrap_or(false) {
        return common.parent().map(Path::to_path_buf);
    }
    Some(common)
}

/// Is this directory a linked git worktree at all? (A plain directory with a `.git` *dir* is a
/// checkout - the canonical one - and is never reaped here.)
fn is_linked_worktree(path: &Path) -> bool {
    let dot_git = path.join(".git");
    match std::fs::symlink_metadata(&dot_git) {
        Ok(meta) => meta.is_file(),
        Err(_) => false,
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    Landed,
    Keep(String),
}

/// The landed-worktree rule, as a yes/no with a reason. Every "no" is a named reason, because
/// "nothing to do" and "I did not look" must not read the same.
pub fn worktree_verdict(path: &Path) -> Verdict {
    if !is_linked_worktree(path) {
        return Verdict::Keep("not a linked git worktree (a plain directory here is not ours to remove)".into());
    }
    let branch = match git(path, &["rev-parse", "--abbrev-ref", "HEAD"]) {
        Some(branch) => branch,
        None => return Verdict::Keep("its git state cannot be read".into()),
    };
    if branch == "HEAD" {
        return Verdict::Keep("detached: a deploy/rollback pin or a scratch tree, never removed automatically".into());
    }
    if git(path, &["rev-parse", "--verify", "--quiet", "refs/remotes/origin/main"]).is_none()
        && git(path, &["rev-parse", "--verify", "--quiet", "origin/main"]).is_none()
    {
        return Verdict::Keep("no origin/main here to judge the branch against".into());
    }
    let merged = git(path, &["merge-base", "--is-ancestor", "HEAD", "origin/main"]).is_some();
    if !merged {
        return Verdict::Keep(format!("{branch} is not merged into origin/main"));
    }
    match git(path, &["status", "--porcelain", "--untracked-files=all"]) {
        Some(dirt) if !dirt.is_empty() => {
            Verdict::Keep(format!("{branch} landed but the tree holds drafts ({} change(s))", dirt.lines().count()))
        }
        Some(_) => Verdict::Landed,
        None => Verdict::Keep("its working tree state cannot be read".into()),
    }
}

// ---------------------------------------------------------------------------------------------------
// the plan
// ---------------------------------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct Entry {
    pub path: PathBuf,
    pub bytes: u64,
    pub files: u64,
    /// `true` when the plan would delete it.
    pub delete: bool,
    pub reason: String,
}

#[derive(Clone, Debug)]
pub struct Group {
    pub name: &'static str,
    pub entries: Vec<Entry>,
}

impl Group {
    fn delete_bytes(&self) -> u64 {
        self.entries.iter().filter(|e| e.delete).map(|e| e.bytes).sum()
    }
    fn bytes(&self) -> u64 {
        self.entries.iter().map(|e| e.bytes).sum()
    }
}

/// Everything the groups look at, as one plan, with the build cap read from the node's environment
/// (`WASM_AGENT_BUILD_CAP_GB`, default 30 GB). The tests call [`plan_with_cap`] so a cap is a number
/// they name, never a process-wide variable a parallel test could change under them.
pub fn plan(root: &Path, days: u64, now: u64) -> Result<Vec<Group>, String> {
    plan_with_cap(root, days, now, build_cap_bytes())
}

/// [`plan`] against a named build-space cap, in bytes.
pub fn plan_with_cap(root: &Path, days: u64, now: u64, cap: u64) -> Result<Vec<Group>, String> {
    if !root.is_dir() {
        return Err(format!("root_missing: {} is not a directory", root.display()));
    }
    let pins = read_pins(root);
    let mut groups = Vec::new();

    // ---- worktrees: only a landed, clean, unpinned, attached one goes ------------------------------
    let mut worktrees = Vec::new();
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(root.join("worktrees")) {
        candidates.extend(entries.flatten().map(|entry| entry.path()).filter(|path| path.is_dir()));
    }
    // Session worktrees already live under the root (`lua/core/workspaces.lua` writes
    // `<root>/wa-worktree-<session>`), so they are candidates too - the same rule judges them.
    if let Ok(entries) = std::fs::read_dir(root) {
        candidates.extend(
            entries
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| {
                    path.is_dir()
                        && path
                            .file_name()
                            .and_then(|name| name.to_str())
                            .map(|name| name.starts_with("wa-worktree-"))
                            .unwrap_or(false)
                }),
        );
    }
    candidates.sort();
    for path in candidates {
        let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        if PROTECTED.contains(&name.as_str()) {
            continue;
        }
        let (bytes, files) = measure(&path);
        let (delete, reason) = match guard_inside(root, &path) {
            Err(reason) => (false, reason),
            Ok(_) => match pinned(root, &path, &pins) {
                Some(reason) => (false, reason),
                None => match worktree_verdict(&path) {
                    Verdict::Landed => {
                        let branch = git(&path, &["rev-parse", "--abbrev-ref", "HEAD"]).unwrap_or_default();
                        (true, format!("{branch} is merged into origin/main and the tree is clean"))
                    }
                    Verdict::Keep(reason) => (false, reason),
                },
            },
        };
        worktrees.push(Entry { path, bytes, files, delete, reason });
    }
    groups.push(Group { name: "worktrees", entries: worktrees });

    // ---- the build root: one root, one child per tree, and a hard cap ------------------------------
    // The cap is a rule about SPACE, not about age, so it is judged here - where the plan is made -
    // and not inside the deletion loop: `--dry-run` must show the same victims the real run takes.
    groups.push(build_group(root, days, now, cap));

    // ---- retention groups: older than N days, and settled -----------------------------------------
    // `build` is judged above: its children are cargo target dirs, not things with an age.
    for group in RETENTION_GROUPS.iter().copied().filter(|group| *group != "build") {
        let dir = root.join(group);
        let mut entries = Vec::new();
        if let Ok(children) = std::fs::read_dir(&dir) {
            for child in children.flatten() {
                let path = child.path();
                let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                if PROTECTED.contains(&name.as_str()) {
                    continue;
                }
                let (bytes, files) = measure(&path);
                // The root's children are judged by name first: the build cache's children are
                // per-tree islands (`build_island`), and everything else in these groups is judged by
                // age - with an operation also having to be settled.
                let verdict: (bool, String) = match guard_inside(root, &path) {
                    Err(reason) => (false, reason),
                    Ok(_) => match pinned(root, &path, &pins) {
                        Some(reason) => (false, reason),
                        None => {
                            let age = age_days(&path, now);
                            if age < 0.0 {
                                (false, "its modification time cannot be read".into())
                            } else if age < days as f64 {
                                (false, format!("{age:.1} day(s) old, under the {days}-day retention"))
                            } else if group == "operations" {
                                match settled(&path) {
                                    Ok(true) => (true, format!("settled, {age:.1} day(s) old")),
                                    Ok(false) => (false, "not settled: an operation that may still be running is live work".into()),
                                    Err(reason) => (false, reason),
                                }
                            } else {
                                (true, format!("{age:.1} day(s) old, over the {days}-day retention"))
                            }
                        }
                    },
                };
                let (delete, reason) = verdict;
                entries.push(Entry { path, bytes, files, delete, reason });
            }
        }
        entries.sort_by(|left, right| left.path.cmp(&right.path));
        groups.push(Group { name: group, entries });
    }
    Ok(groups)
}

/// A build island's verdict: whose output it is, and whether that tree is finished.
///
/// "A finished worktree and its build outputs" is one decision, not two, so the island carries the
/// path of the tree it was built from (`ISLAND_MARKER`) and is judged by the same landed/clean/detached
/// rule as the worktree itself. An island without a marker predates this layout: it falls back to the
/// age rule, and says so.
fn island_verdict(path: &Path, days: u64, now: u64) -> (bool, String) {
    match std::fs::read_to_string(path.join(ISLAND_MARKER)) {
        Ok(text) => {
            let tree = PathBuf::from(text.trim());
            if !tree.exists() {
                return (true, format!("build output of a tree that is gone ({})", tree.display()));
            }
            match worktree_verdict(&tree) {
                Verdict::Landed => (true, format!("build output of a landed tree ({})", tree.display())),
                Verdict::Keep(reason) => (false, format!("build output of a tree still in use: {reason}")),
            }
        }
        Err(_) => {
            let age = age_days(path, now);
            if age < 0.0 {
                (false, "its modification time cannot be read".into())
            } else if age < days as f64 {
                (false, format!("{age:.1} day(s) old, under the {days}-day retention"))
            } else {
                (true, format!("{age:.1} day(s) old, over the {days}-day retention"))
            }
        }
    }
}

/// Is this operation record settled? A record with no `state.json`, or one that says anything other
/// than completed/failed/cancelled, is live: an unknown effect is never replayed *or* deleted.
fn settled(dir: &Path) -> Result<bool, String> {
    let file = dir.join("state.json");
    let text = match std::fs::read_to_string(&file) {
        Ok(text) => text,
        Err(_) => return Err("no operation state: treated as live".into()),
    };
    let state: Value = match serde_json::from_str(&text) {
        Ok(state) => state,
        Err(_) => return Err("its operation state cannot be parsed: treated as live".into()),
    };
    let name = state["state"].as_str().unwrap_or("");
    let settled = state["settled"].as_bool().unwrap_or(false);
    if settled || matches!(name, "completed" | "failed" | "cancelled") {
        Ok(true)
    } else {
        Ok(false)
    }
}

// ---------------------------------------------------------------------------------------------------
// the build root: one root, a child per tree, and a hard cap
// ---------------------------------------------------------------------------------------------------

/// The file inside a per-tree build dir that names the tree it was built from.
pub const ISLAND_MARKER: &str = "tree";

/// The cap on build space, in GB. `WASM_AGENT_BUILD_CAP_GB` names another one; 30 GB is the default
/// the operator asked for, and it has to hold `launch(wa) + a release build of every crate in use`.
pub const BUILD_CAP_GB_ENV: &str = "WASM_AGENT_BUILD_CAP_GB";
pub const DEFAULT_BUILD_CAP_GB: u64 = 30;

/// The build cap in bytes: `WASM_AGENT_BUILD_CAP_GB` (decimal GB), else [`DEFAULT_BUILD_CAP_GB`].
///
/// `scripts/lib/build-target.sh::wa_build_cap_bytes` reads the same variable and computes the same
/// number, because the sweep before a build and `wa clean` must agree about what "over the cap" means.
pub fn build_cap_bytes() -> u64 {
    std::env::var(BUILD_CAP_GB_ENV)
        .ok()
        .and_then(|raw| raw.trim().parse::<f64>().ok())
        .filter(|gb| *gb > 0.0)
        .map(|gb| (gb * 1_000_000_000.0) as u64)
        .unwrap_or(DEFAULT_BUILD_CAP_GB * 1_000_000_000)
}

/// The `build` group of the plan: the one build root's per-tree target dirs, everything an older
/// layout left beside them, and the cap that decides which of them goes first.
///
/// Three rules, in this order, because they answer three different questions:
///
///   1. an island whose tree is **gone or landed** goes (`island_verdict`) - a finished worktree and
///      its build outputs are one decision;
///   2. anything under `<root>/build` that is **not** the `target` child is an island an older layout
///      wrote (73 of them, 196 GB, on this node on 13/11): it goes, and the reason says why;
///   3. past the **cap**, the oldest build output goes first until the space fits. The tree being
///      built right now is not special here: the plan is about space, and a build that needs room it
///      does not have has to wait for the sweep `scripts/lib/build-target.sh` runs before it starts.
fn build_group(root: &Path, days: u64, now: u64, cap: u64) -> Group {
    let build_root = root.join("build");
    let target_root = build_root.join("target");
    let mut entries = Vec::new();
    // Islands from the layout this replaces, and anything else that is not the one target root.
    if let Ok(children) = std::fs::read_dir(&build_root) {
        for child in children.flatten() {
            let path = child.path();
            let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            if name == "target" || PROTECTED.contains(&name.as_str()) {
                continue;
            }
            let (bytes, files) = measure(&path);
            let (delete, reason) = match guard_inside(root, &path) {
                Err(reason) => (false, reason),
                Ok(_) => (true, "an island from the layout this replaced: the node has one build root (build/target) now, and old space goes before a build uses new".to_string()),
            };
            entries.push(Entry { path, bytes, files, delete, reason });
        }
    }
    // The one build root's children: one cargo target dir per tree, named by the tree.
    if let Ok(children) = std::fs::read_dir(&target_root) {
        for child in children.flatten() {
            let path = child.path();
            if !path.is_dir() {
                continue;
            }
            let (bytes, files) = measure(&path);
            let (delete, reason) = match guard_inside(root, &path) {
                Err(reason) => (false, reason),
                Ok(_) => island_verdict(&path, days, now),
            };
            entries.push(Entry { path, bytes, files, delete, reason });
        }
    }
    entries.sort_by(|left, right| left.path.cmp(&right.path));

    // Rule 3: the cap. The oldest build output goes first - "mtime of the directory" is "when a build
    // last wrote there", which is exactly the question "which of these will a build wait on longest".
    let total: u64 = entries.iter().map(|entry| entry.bytes).sum();
    if total > cap {
        let mut order: Vec<usize> = (0..entries.len()).collect();
        // Oldest first, then by name: two build dirs written in the same second must still be evicted in
        // a fixed order, or a bisect of this rule is a race.
        order.sort_by_key(|index| (modified(&entries[*index].path), entries[*index].path.clone()));
        let mut over = total;
        for index in order {
            if over <= cap {
                break;
            }
            let entry = &mut entries[index];
            if entry.delete {
                // Already going for its own reason: its bytes are part of the reclaim either way.
                over = over.saturating_sub(entry.bytes);
                continue;
            }
            entry.delete = true;
            entry.reason = format!(
                "over the {} GB build cap ({} bytes used of {}): the oldest build output goes first",
                cap / 1_000_000_000,
                total,
                cap
            );
            over = over.saturating_sub(entry.bytes);
        }
    }
    Group { name: "build", entries }
}

/// When a build dir was last written to, as epoch seconds (0 when it cannot be read, which makes it
/// the first candidate for eviction - an unreadable build dir is not worth keeping).
fn modified(path: &Path) -> u64 {
    std::fs::metadata(path)
        .and_then(|meta| meta.modified())
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|since| since.as_secs())
        .unwrap_or(0)
}

/// `<root>/build/target/<tree>-<hash>`: where one tree's cargo output lives.
///
/// ONE ROOT, ONE CHILD PER TREE - and why the children are per tree is the part that must not be
/// "simplified" away later. A single FLAT `CARGO_TARGET_DIR` for every tree on a node was measured
/// here on 12/11 (3 m 25 s and 7.6 GB cold, a second worktree reusing the same dir in 1 m 34 s, and
/// then `cannot find function state_root in module wa_host_support::paths` when the first tree was
/// rebuilt) and REPRODUCED on 13/11 in seconds with a two-member fixture
/// (`scripts/test-onebuild.mjs`, which keeps it as a check):
///
///   1. tree A and tree B are two checkouts of `rust/Cargo.toml` - the same workspace, the same
///      members, the same relative paths, at two absolute paths;
///   2. cargo gives a workspace member the same unit hash in both trees, so both trees' builds of
///      `libbase`/`libwa_host_support` land on the SAME file name in the shared dir;
///   3. tree B adds `pub fn g()` to its `base` and builds; back in tree A, `cargo build` was a no-op
///      and A's binary printed `base=1 g=2` - **tree A ran tree B's library**.
///
/// That is the failure this project keeps paying for: a verdict about a tree that was never loaded.
/// Cargo has no supported way to key a workspace member's artifacts by the checkout path, so the
/// target dir itself has to be per tree. What is shared is the root: one directory, one `wa clean`,
/// one `wa status` line, one cap, one owner - and no artifact crosses a tree.
///
/// The name is `<basename>-<first 12 hex of sha256 of the tree's canonical path>`, which
/// `scripts/lib/build-target.sh::wa_build_tree_name` computes with `sha256sum`; the two sides are
/// compared by `scripts/test-onebuild.mjs` and `scripts/test-oneroot.lua`.
pub fn build_island(tree: &Path) -> Option<PathBuf> {
    build_island_in(&wa_host_support::paths::build_cache_dir(), tree)
}

/// [`build_island`] inside a named build root. The tests use this one, so a unit test writes its
/// islands in its own scratch directory and never in a live node's root.
pub fn build_island_in(build_root: &Path, tree: &Path) -> Option<PathBuf> {
    // The canonical path when it can be resolved; an ABSOLUTE path as given when it cannot, because a
    // tree that has just been removed (`control("forget")`, `clean`) still has its build output named
    // after it. `scripts/lib/build-target.sh::wa_build_tree_name` falls back the same way, which is what
    // keeps the two names equal.
    let canonical = match std::fs::canonicalize(tree) {
        Ok(path) => path,
        Err(_) if tree.is_absolute() => tree.to_path_buf(),
        Err(_) => return None,
    };
    let text = canonical.to_string_lossy().replace('\\', "/");
    let digest = ring::digest::digest(&ring::digest::SHA256, text.as_bytes());
    let hash: String = digest.as_ref().iter().take(6).map(|byte| format!("{byte:02x}")).collect();
    let name: String = canonical
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| "tree".into())
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '-' })
        .collect();
    Some(build_root.join("target").join(format!("{name}-{hash}")))
}

/// Does this directory look like something cargo can build? Used to avoid filling `<root>/build` with
/// an island for every directory a shell happens to run in.
pub fn is_cargo_tree(tree: &Path) -> bool {
    tree.join("rust").join("Cargo.toml").is_file() || tree.join("Cargo.toml").is_file()
}

/// `CARGO_TARGET_DIR` for a child process starting in `tree`, and the marker written so `wa clean` can
/// tell whose output it is. `None` when this is not a cargo tree or the directory cannot be created - a
/// child is never pointed at a directory that is not there.
pub fn build_env_for(tree: &Path) -> Option<PathBuf> {
    build_env_for_in(&wa_host_support::paths::build_cache_dir(), tree)
}

/// [`build_env_for`] inside a named build root (see [`build_island_in`]).
pub fn build_env_for_in(build_root: &Path, tree: &Path) -> Option<PathBuf> {
    if !is_cargo_tree(tree) {
        return None;
    }
    let island = build_island_in(build_root, tree)?;
    std::fs::create_dir_all(&island).ok()?;
    if let Ok(canonical) = std::fs::canonicalize(tree) {
        let _ = std::fs::write(island.join(ISLAND_MARKER), canonical.to_string_lossy().as_bytes());
    }
    Some(island)
}

/// The build space one tree occupies right now, and where it is: what the sweep before a build and
/// `wa build --status` report.
pub fn build_space(tree: &Path) -> Option<(PathBuf, u64)> {
    let island = build_island(tree)?;
    if !island.exists() {
        return None;
    }
    Some((island.clone(), measure(&island).0))
}

// ---------------------------------------------------------------------------------------------------
// the command
// ---------------------------------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct CleanOptions {
    pub days: u64,
    pub dry_run: bool,
    pub now: u64,
}

pub fn clean(root: &Path, options: &CleanOptions) -> Result<Value, String> {
    let groups = plan(root, options.days, options.now)?;
    let mut freed: u64 = 0;
    let mut deleted: u64 = 0;
    let mut islands_deleted: u64 = 0;
    let mut kept: u64 = 0;
    let mut refused: Vec<Value> = Vec::new();
    let mut rows_json: Vec<Value> = Vec::new();

    for group in &groups {
        let mut rows = Vec::new();
        // The reader wants the bytes that would go, and then why so much stays: deletable rows first,
        // biggest first, and a reason histogram for the keeps.
        let mut ordered: Vec<&Entry> = group.entries.iter().collect();
        ordered.sort_by(|left, right| right.delete.cmp(&left.delete).then(right.bytes.cmp(&left.bytes)));
        for entry in ordered {
            if !entry.delete {
                kept += 1;
                if entry.reason.starts_with("outside_root") || entry.reason.starts_with("symlink") {
                    refused.push(json!({"path": entry.path.to_string_lossy(), "reason": entry.reason}));
                }
            } else if options.dry_run {
                deleted += 1;
                freed = freed.saturating_add(entry.bytes);
            } else {
                // The island has to be named BEFORE the tree goes: `build_island` canonicalizes the tree
                // path, and a removed worktree has no path to canonicalize.
                let island = if group.name == "worktrees" {
                    build_island(&entry.path).filter(|island| island.exists())
                } else {
                    None
                };
                match remove(&entry.path) {
                    Ok(()) => {
                        deleted += 1;
                        freed = freed.saturating_add(entry.bytes);
                        // A finished worktree and its build outputs are ONE decision (`docs/ONEROOT.md`):
                        // the plan kept this island because its tree was still there, so this same run
                        // takes it - otherwise every removal costs the next clean a second pass, which is
                        // exactly how 73 build folders (~196 GB) survived on this node.
                        if let Some(island) = island {
                            let (bytes, _files) = measure(&island);
                            if remove(&island).is_ok() {
                                freed = freed.saturating_add(bytes);
                                islands_deleted += 1;
                            }
                        }
                    }
                    Err(reason) => {
                        kept += 1;
                        refused.push(json!({"path": entry.path.to_string_lossy(), "reason": reason}));
                    }
                }
            }
            if rows.len() < ROW_LIMIT {
                rows.push(json!({
                    "path": entry.path.to_string_lossy(),
                    "bytes": entry.bytes,
                    "files": entry.files,
                    "delete": entry.delete,
                    "reason": entry.reason,
                }));
            }
        }
        let mut reasons: std::collections::BTreeMap<String, u64> = std::collections::BTreeMap::new();
        for entry in group.entries.iter().filter(|entry| !entry.delete) {
            // The same reason for 4000 lease files is one line, not 4000: group by the shape of it.
            let key = entry.reason.clone();
            *reasons.entry(key).or_insert(0) += 1;
        }
        let mut kept_reasons: Vec<Value> = reasons
            .iter()
            .map(|(reason, count)| json!({"reason": reason, "count": count}))
            .collect();
        kept_reasons.sort_by(|left, right| right["count"].as_u64().cmp(&left["count"].as_u64()));
        kept_reasons.truncate(4);
        rows_json.push(json!({
            "name": group.name,
            "bytes": group.bytes(),
            "files": group.entries.iter().map(|e| e.files).sum::<u64>(),
            "delete_bytes": group.delete_bytes(),
            "delete_entries": group.entries.iter().filter(|e| e.delete).count(),
            "entries": group.entries.len(),
            "kept_reasons": kept_reasons,
            "rows": rows,
            "rows_truncated": group.entries.len().saturating_sub(rows.len()),
        }));
    }

    let record = json!({
        "at": options.now,
        "freed_bytes": if options.dry_run { 0 } else { freed },
        "would_free_bytes": freed,
        "deleted": deleted,
        "kept": kept,
        "dry_run": options.dry_run,
    });
    if !options.dry_run {
        let file = root.join("clean").join("last.json");
        if let Some(parent) = file.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(&file, serde_json::to_vec_pretty(&record).unwrap_or_default());
    }

    Ok(json!({
        "ok": true,
        "root": root.to_string_lossy(),
        "dry_run": options.dry_run,
        "days": options.days,
        "groups": rows_json,
        "outside": outside(root),
        "build_cap_bytes": build_cap_bytes(),
        "build_islands_deleted": islands_deleted,
        "freed_bytes": if options.dry_run { 0 } else { freed },
        "would_free_bytes": freed,
        "deleted": deleted,
        "kept": kept,
        "refused": refused,
        "record": record,
    }))
}

/// Remove one entry: a git worktree through git (so the registration goes too), anything else with a
/// recursive delete that never follows a link.
fn remove(path: &Path) -> Result<(), String> {
    if is_linked_worktree(path) {
        if let Some(canonical) = canonical_of_worktree(path) {
            let output = std::process::Command::new("git")
                .arg("-C")
                .arg(&canonical)
                .args(["worktree", "remove", "--force"])
                .arg(path)
                .env("GIT_TERMINAL_PROMPT", "0")
                .output()
                .map_err(|error| format!("git_worktree_remove_failed: {error}"))?;
            if output.status.success() {
                return Ok(());
            }
            return Err(format!(
                "git_worktree_remove_failed: {}",
                String::from_utf8_lossy(&output.stderr).trim().lines().last().unwrap_or("no message")
            ));
        }
    }
    let meta = std::fs::symlink_metadata(path).map_err(|error| format!("unreadable: {error}"))?;
    let result = if meta.is_dir() {
        std::fs::remove_dir_all(path)
    } else {
        std::fs::remove_file(path)
    };
    result.map_err(|error| format!("remove_failed: {error}"))
}

// ---------------------------------------------------------------------------------------------------
// the cap
// ---------------------------------------------------------------------------------------------------

/// The cap check the node runs before new heavy work (a build, a test, a deploy, a session).
///
/// Under the cap: one cheap measurement, nothing else. Over it: the same `clean` as the command, then
/// a second measurement. Still over: a refusal by name (`disk_cap`) that says the numbers, instead of
/// work that fills the disk and dies half way - which is what `os error 112` in the middle of a gate
/// is (see `scripts/check-disk-floor.sh`, measured 30/9).
pub fn guard(root: &Path, trigger: &str) -> Result<Value, String> {
    let cap = cap_percent();
    let days = retention_days();
    let usage = match disk_usage(root) {
        Some(usage) => usage,
        None => {
            return Ok(json!({
                "ok": true, "checked": false, "trigger": trigger,
                "reason": "disk_percent_unavailable: this platform's free space cannot be measured, so no cap is enforced here",
            }))
        }
    };
    if usage.used_percent <= cap {
        return Ok(json!({
            "ok": true, "checked": true, "trigger": trigger, "cleaned": false,
            "used_percent": usage.used_percent, "cap_percent": cap,
        }));
    }
    let before = usage.used_percent;
    let options = CleanOptions { days, dry_run: false, now: now_epoch() };
    let cleaned = clean(root, &options)?;
    let freed = cleaned["freed_bytes"].as_u64().unwrap_or(0);
    let after = disk_usage(root);
    match after {
        Some(usage) if usage.used_percent <= cap => Ok(json!({
            "ok": true, "checked": true, "trigger": trigger, "cleaned": true,
            "used_percent_before": before, "used_percent": usage.used_percent,
            "cap_percent": cap, "freed_bytes": freed,
            "note": format!("the root's filesystem was {before:.1}% full; one clean freed {freed} bytes and brought it to {:.1}% (cap {cap:.0}%)", usage.used_percent),
        })),
        Some(usage) => Err(format!(
            "disk_cap: the root's filesystem is {:.1}% full (cap {cap:.0}%) and one clean could not bring it under, so new {trigger} work is refused by name. Freed {freed} bytes. `wa clean --dry-run` names what is left and why it is kept.",
            usage.used_percent
        )),
        None => Err(format!(
            "disk_cap: the root's filesystem was {before:.1}% full (cap {cap:.0}%), one clean freed {freed} bytes, and the result cannot be measured now - refusing new {trigger} work rather than assuming it worked"
        )),
    }
}

/// The cap check with the once-a-minute cache the hot path needs: a `bash` call may spawn a dozen
/// children, and each of them asking `statvfs` and possibly cleaning is not a check, it is a stampede.
pub fn guard_cached(root: &Path, trigger: &str) -> Result<Value, String> {
    use std::sync::Mutex;
    use std::time::Instant;
    static LAST: Mutex<Option<Instant>> = Mutex::new(None);
    if let Ok(guard) = LAST.lock() {
        if let Some(at) = *guard {
            if at.elapsed().as_secs() < 60 {
                return Ok(json!({"ok": true, "checked": false, "trigger": trigger, "reason": "checked within the last 60 s"}));
            }
        }
    }
    let result = guard(root, trigger);
    let ok = result.is_ok();
    if ok {
        if let Ok(mut guard) = LAST.lock() {
            *guard = Some(Instant::now());
        }
    }
    result
}

// ---------------------------------------------------------------------------------------------------
// status
// ---------------------------------------------------------------------------------------------------

pub fn status(root: &Path) -> Result<Value, String> {
    let mut groups = serde_json::Map::new();
    let mut total_bytes = 0u64;
    let mut total_files = 0u64;
    let mut sweep = vec![root.join("worktrees")];
    for group in RETENTION_GROUPS {
        sweep.push(root.join(group));
    }
    if let Ok(entries) = std::fs::read_dir(root) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("wa-worktree-") && entry.path().is_dir() {
                sweep.push(entry.path());
            }
        }
    }
    for path in sweep {
        if !path.is_dir() {
            continue;
        }
        let (bytes, files) = measure(&path);
        total_bytes = total_bytes.saturating_add(bytes);
        total_files = total_files.saturating_add(files);
        let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        groups.insert(
            if name.starts_with("wa-worktree-") { "session-worktrees".to_string() } else { name },
            json!({"path": path.to_string_lossy(), "bytes": bytes, "files": files}),
        );
    }
    let usage = disk_usage(root);
    let cap = cap_percent();
    let last = std::fs::read_to_string(root.join("clean").join("last.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok());
    let pins = read_pins(root);
    Ok(json!({
        "ok": true,
        "root": root.to_string_lossy(),
        "bytes": total_bytes,
        "files": total_files,
        "groups": groups,
        "disk": match usage {
            Some(usage) => json!({"total_bytes": usage.total_bytes, "free_bytes": usage.free_bytes, "used_percent": usage.used_percent}),
            None => Value::Null,
        },
        "disk_reason": if usage.is_none() { json!("disk_percent_unavailable") } else { Value::Null },
        "cap_percent": cap,
        "over_cap": usage.map(|usage| usage.used_percent > cap).unwrap_or(false),
        "days": retention_days(),
        "pins": pins.iter().map(|pin| pin.to_string_lossy().to_string()).collect::<Vec<_>>(),
        // The build root, as facts a reader can act on: how much build space this node holds, the cap
        // it must stay under, and the one directory that owns it (`docs/ONEROOT.md`).
        "build_target": wa_host_support::paths::build_target_dir().to_string_lossy(),
        "build_bytes": measure(&wa_host_support::paths::build_cache_dir()).0,
        "build_cap_bytes": build_cap_bytes(),
        "build_over_cap": measure(&wa_host_support::paths::build_cache_dir()).0 > build_cap_bytes(),
        "last_clean": last,
    }))
}

// ---------------------------------------------------------------------------------------------------
// the capability
// ---------------------------------------------------------------------------------------------------

/// `host.disk(action, args_json)` -> result | {ok:false, error}
///
/// Actions: `status` (read-only), `clean` (`dry_run`, `days`), `pin` / `unpin` (`path`), `guard`
/// (`trigger`). The root is always the node's own state root: a caller cannot point `wa clean` at
/// another directory, because the whole promise is "inside the root and nowhere else".
pub fn control(action: &str, args: &Value) -> Result<Value, String> {
    let root = wa_host_support::paths::state_root();
    match action {
        "status" => status(&root),
        "clean" => {
            let dry_run = args["dry_run"].as_bool().unwrap_or(false);
            let days = args["days"].as_u64().filter(|days| *days > 0).unwrap_or_else(retention_days);
            clean(&root, &CleanOptions { days, dry_run, now: now_epoch() })
        }
        "pin" | "unpin" => {
            let given = args["path"].as_str().unwrap_or("").trim().to_string();
            if given.is_empty() {
                return Err("path_required".into());
            }
            let path = PathBuf::from(&given);
            let absolute = if path.is_absolute() { path.clone() } else { root.join(&path) };
            // A pin is a promise about a path inside the root; a pin on something else would only
            // teach the reader that pins do not mean inside-the-root.
            guard_inside(&root, &absolute).map_err(|error| format!("pin_refused: {error}"))?;
            let mut pins = read_pins(&root);
            pins.retain(|pin| pin != &absolute);
            if action == "pin" {
                pins.push(absolute.clone());
            }
            write_pins(&root, &pins)?;
            Ok(json!({"ok": true, "action": action, "path": absolute.to_string_lossy(), "pins": pins.len()}))
        }
        "island" => {
            // Read-only, and it exists so the two programs that must agree on an island's name can be
            // checked against each other: this side (`build_island`, sha256 via ring) and
            // `scripts/lib/fast-binary.sh` (sha256sum). `scripts/test-oneroot.lua` compares them.
            let given = args["path"].as_str().unwrap_or("").trim().to_string();
            if given.is_empty() {
                return Err("path_required".into());
            }
            let tree = PathBuf::from(&given);
            let island = build_island(&tree).ok_or_else(|| format!("unreadable: {given}"))?;
            Ok(json!({
                "ok": true,
                "tree": std::fs::canonicalize(&tree).map(|path| path.to_string_lossy().to_string()).unwrap_or(given),
                "island": island.to_string_lossy(),
                // The directory cargo writes: the island itself, one child of the one build root.
                "target": island.to_string_lossy(),
                "build_target_root": wa_host_support::paths::build_target_dir().to_string_lossy(),
                "cargo_tree": is_cargo_tree(&tree),
            }))
        }
        "forget" => {
            // A tree went away (a released session worktree, a reaped landing worktree): its build
            // output goes with it, in the same call, because "a finished worktree and its build outputs"
            // is one decision (`docs/ONEROOT.md`). The name is [`build_island`]'s, so this cannot drift
            // from the directory a build actually writes.
            let given = args["path"].as_str().unwrap_or("").trim().to_string();
            if given.is_empty() {
                return Err("path_required".into());
            }
            let island = build_island(Path::new(&given)).ok_or_else(|| format!("unreadable: {given}"))?;
            let inside = guard_inside(&root, &island).map_err(|error| format!("forget_refused: {error}"))?;
            if !inside.exists() {
                return Ok(json!({"ok": true, "tree": given, "build": island.to_string_lossy(), "freed_bytes": 0}));
            }
            let (bytes, files) = measure(&inside);
            remove(&inside).map_err(|error| format!("forget_failed: {error}"))?;
            Ok(json!({
                "ok": true,
                "tree": given,
                "build": island.to_string_lossy(),
                "freed_bytes": bytes,
                "files": files,
            }))
        }
        "guard" => {
            let trigger = args["trigger"].as_str().filter(|t| !t.is_empty()).unwrap_or("work");
            guard(&root, trigger)
        }
        other => Err(format!("unknown_disk_action: {other}")),
    }
}

/// `host.disk(action, args_json)` -> result | {ok:false, error}
///
/// The Lua half is `lua/core/clean.lua`: `wa clean` and the root line in `wa status`. Every rule lives
/// on this side, because a deletion policy in Lua would be a policy the CLI could change by accident.
pub extern "C-unwind" fn capability(l: *mut LuaState) -> std::ffi::c_int {
    let action = arg_string(l, 1).filter(|action| !action.is_empty()).unwrap_or_else(|| "status".into());
    let args: Value = arg_string(l, 2)
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or(Value::Null);
    let answer = control(&action, &args).unwrap_or_else(|error| json!({"ok": false, "error": error}));
    wa_host_support::json::push_json(l, &answer);
    1
}

#[cfg(test)]
#[path = "disk_tests.rs"]
mod tests;
