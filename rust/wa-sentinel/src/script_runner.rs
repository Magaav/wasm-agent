//! Interpreter selection for approved deterministic scripts. No shell fallback for JavaScript.
use anyhow::{bail, Context, Result};
use std::ffi::OsString;
use std::path::{Path, PathBuf};

fn executable(path: &Path) -> bool {
    if !path.is_file() { return false; }
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        return path.metadata().is_ok_and(|m| m.permissions().mode() & 0o111 != 0);
    }
    #[cfg(not(unix))] { true }
}

fn resolve_node(explicit: Option<OsString>, search: Option<OsString>, fallbacks: &[PathBuf]) -> Result<PathBuf> {
    if let Some(value) = explicit {
        let path = PathBuf::from(value);
        if !path.is_absolute() || !executable(&path) {
            bail!("node_runtime_unavailable: WA_SENTINEL_NODE must name an absolute executable file; no shell fallback");
        }
        return std::fs::canonicalize(path).context("resolve WA_SENTINEL_NODE");
    }
    let name = if cfg!(windows) { "node.exe" } else { "node" };
    // Do not search cwd via an empty/relative PATH entry. Resolve once, then launch the exact file.
    let candidates = search.iter().flat_map(|value| std::env::split_paths(value))
        .filter(|dir| dir.is_absolute()).map(|dir| dir.join(name))
        .chain(fallbacks.iter().cloned());
    for path in candidates {
        if executable(&path) {
            return std::fs::canonicalize(path).context("resolve Node executable");
        }
    }
    bail!("node_runtime_unavailable: install Node on the sentinel PATH or set WA_SENTINEL_NODE to its absolute executable; no shell fallback")
}

pub(crate) fn node_runtime() -> Result<PathBuf> {
    let mut fallbacks = Vec::new();
    if cfg!(windows) {
        // Detached Windows watchers often lack the interactive shell's PATH.
        for key in ["ProgramW6432", "ProgramFiles", "ProgramFiles(x86)"] {
            if let Some(root) = std::env::var_os(key) {
                let root = PathBuf::from(root);
                if root.is_absolute() { fallbacks.push(root.join("nodejs/node.exe")); }
            }
        }
    }
    resolve_node(std::env::var_os("WA_SENTINEL_NODE"), std::env::var_os("PATH"), &fallbacks)
}

fn native_argument(path: &Path) -> String {
    let text = path.display().to_string();
    if cfg!(windows) {
        if let Some(rest) = text.strip_prefix(r"\\?\UNC\") { return format!(r"\\{}", rest); }
        return text.strip_prefix(r"\\?\").unwrap_or(&text).to_string();
    }
    text
}

pub(crate) fn command(path: &Path) -> Result<(String, Vec<String>)> {
    let suffix = path.extension().and_then(|s| s.to_str()).unwrap_or("").to_ascii_lowercase();
    if matches!(suffix.as_str(), "js" | "mjs" | "cjs") {
        let program = node_runtime()?;
        return Ok((program.display().to_string(), vec!["--".into(), native_argument(path)]));
    }
    if suffix == "ps1" {
        #[cfg(windows)] {
            let root = std::env::var_os("SystemRoot").context("powershell_system_root_unavailable")?;
            let program = PathBuf::from(root).join("System32/WindowsPowerShell/v1.0/powershell.exe");
            if !executable(&program) { bail!("powershell_runtime_unavailable"); }
            return Ok((program.display().to_string(), vec!["-NoProfile".into(), "-NonInteractive".into(), "-File".into(), native_argument(path)]));
        }
        #[cfg(not(windows))] { bail!("powershell_script_requires_windows; no shell fallback"); }
    }
    let (program, argument) = crate::shell_for(path);
    Ok((program, vec![argument]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn node_resolution_requires_an_executable_and_never_searches_relative_path_entries() {
        let root = std::env::temp_dir().join(format!("wa-node-resolver-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let name = if cfg!(windows) { "node.exe" } else { "node" };
        let fake = root.join(name);
        std::fs::write(&fake, "fixture executable, never launched").unwrap();
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            assert!(resolve_node(Some(fake.clone().into_os_string()), None, &[]).is_err());
            std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let resolved = std::fs::canonicalize(&fake).unwrap();
        assert_eq!(resolve_node(Some(fake.clone().into_os_string()), None, &[]).unwrap(), resolved);
        assert_eq!(resolve_node(None, Some(std::env::join_paths([&root]).unwrap()), &[]).unwrap(), resolved);
        assert_eq!(resolve_node(None, None, &[fake.clone()]).unwrap(), resolved);
        assert!(resolve_node(Some("node".into()), None, &[fake.clone()]).is_err(), "invalid explicit override must not fall back");
        assert!(resolve_node(Some(root.join("absent").into_os_string()), None, &[fake]).is_err());
        assert!(resolve_node(None, Some(std::env::join_paths([Path::new(""), Path::new(".")]).unwrap()), &[]).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
