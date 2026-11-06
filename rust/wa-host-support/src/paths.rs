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
