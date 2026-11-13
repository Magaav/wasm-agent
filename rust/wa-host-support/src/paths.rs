//! Where the host keeps things. Moved verbatim from `wa-host/src/main.rs` (`resolve_home`,
//! `private_dir`) and `wa-host/src/components.rs` (`component_dir`) so every crate resolves them the
//! same way: one resolution per process, and the crates below cannot import `main`.

/// The user's home directory, which is where `~/.wasm-agent` lives.
///
/// Windows does not set `HOME`, and Git Bash sets it to a POSIX path
/// (`/c/Users/...`) that Rust cannot open - which silently disabled the whole
/// config file, leaving the agent in "no model configured" mode. Prefer an
/// explicit override, then the native Windows variables, then HOME.
pub fn resolve_home() -> String {
    if let Ok(value) = std::env::var("WASM_AGENT_HOME") {
        if !value.is_empty() {
            return value;
        }
    }
    if cfg!(windows) {
        if let Ok(value) = std::env::var("USERPROFILE") {
            if !value.is_empty() {
                return value;
            }
        }
        if let (Ok(drive), Ok(path)) = (std::env::var("HOMEDRIVE"), std::env::var("HOMEPATH")) {
            if !drive.is_empty() && !path.is_empty() {
                return format!("{drive}{path}");
            }
        }
    }
    std::env::var("HOME").unwrap_or_else(|_| ".".into())
}

/// Create the node's state directory readable by its owner only. It holds transcripts, the node key
/// and credentials; with a default umask those were readable by every local user.
/// An existing directory is tightened only if it is the node's own `.wasm-agent`.
pub fn private_dir(path: &std::path::Path) {
    let existed = path.exists();
    let _ = std::fs::create_dir_all(path);
    #[cfg(unix)]
    if !existed || path.file_name().is_some_and(|name| name == ".wasm-agent") {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
    }
    #[cfg(not(unix))]
    let _ = existed;
}

/// The one root everything an agent creates lives under: `<home>/.wasm-agent` (`docs/ONEROOT.md`).
///
/// It is the state root the node already had (the ledger, sessions, memory, `operations/`, `cache/`),
/// so this adds a *layout* inside one directory rather than a second root concept. Every new thing an
/// agent or a landing script creates — scratch files, worktrees, build output, logs — goes under it,
/// which is what makes one `wa clean` and one disk cap possible at all.
///
/// Measured 12/11 on wa-desktop after one morning of agents: ~100 GB, of which worktrees were ~45 GB
/// (`~/wt-*`, 42 of them, scattered beside the home) and per-mission build dirs ~25 GB
/// (`rust/target-*`), while this root held 0.4 GB. Nothing cleaned up after the agents.
pub fn state_root() -> std::path::PathBuf {
    std::path::PathBuf::from(resolve_home()).join(".wasm-agent")
}

/// A named directory inside [`state_root`], created if it is not there.
///
/// The layout is flat and obvious on purpose (`docs/ONEROOT.md`): `tmp/`, `worktrees/`, `build/`,
/// `cache/`, `logs/`, `operations/`. A caller asks for the name, never builds the path, so `wa clean`
/// and the thing it cleans cannot drift apart.
pub fn root_dir(name: &str) -> std::path::PathBuf {
    let path = state_root().join(name);
    let _ = std::fs::create_dir_all(&path);
    path
}

/// The scratch root every child process the node spawns gets as `TMPDIR`/`TEMP`/`TMP`.
///
/// `host.paths().temp` and this must be the same directory: a build that writes to `/tmp` is exactly
/// the kind of thing one root exists to stop, and `/tmp` was 98 % full on the `work` node on 12/11.
pub fn tmp_dir() -> std::path::PathBuf {
    root_dir("tmp")
}

/// The one build root of this node: every build kind's output lives under it, and `wa clean` owns it.
pub fn build_cache_dir() -> std::path::PathBuf {
    root_dir("build")
}

/// The one shared cargo target root (`<root>/build/target`), whose children are the per-tree target
/// directories: `CARGO_TARGET_DIR` for a tree is `<root>/build/target/<tree>-<hash>`.
///
/// One direct child per tree is not a detail - see [`crate::disk::build_island`] for the measurement
/// that shows what a FLAT shared target dir does to two worktrees of this workspace.
pub fn build_target_dir() -> std::path::PathBuf {
    build_cache_dir().join("target")
}

/// Where agent and landing worktrees are created (`docs/ONEROOT.md`).
pub fn worktrees_dir() -> std::path::PathBuf {
    root_dir("worktrees")
}

/// Where installed WASI components live (`WA_COMPONENTS_DIR`, else `~/.wasm-agent/components`).
///
/// It is here rather than in `components.rs` because the bound queue and the graph store ask for it
/// too, and neither may depend on the kernel crate.
pub fn component_dir() -> std::path::PathBuf {
    if let Ok(path) = std::env::var("WA_COMPONENTS_DIR") {
        return std::path::PathBuf::from(path);
    }
    let home = std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")).unwrap_or_else(|_| ".".into());
    std::path::PathBuf::from(home).join(".wasm-agent").join("components")
}
