//! Building a component crate for `wasm32-wasip2`: the one step `wa dev` repeats on every change,
//! kept here so the dev loop, the tests and the CLI all ask cargo the same way.
//!
//! Where the artifact lands is read from `cargo metadata`, never guessed: a component's crate name
//! and its `.wasm` file name differ (`fake-kernel-fixture` builds `fake_kernel_fixture.wasm`), and a
//! `CARGO_TARGET_DIR` anywhere in the environment moves both. A build that succeeds but whose
//! artifact cannot be found is an error with the paths in it, not an empty result.

use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

/// A finished build: the artifact, how long cargo took, and how big it is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Built {
    pub wasm: PathBuf,
    pub millis: u64,
    pub bytes: u64,
}

/// What a component crate declares: its package name and where cargo will put its `.wasm`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Layout {
    /// `<target_directory>/wasm32-wasip2/<debug|release>`
    pub target_dir: PathBuf,
    pub wasm: PathBuf,
    /// The cdylib's target name, which is also the component's directory name by convention.
    pub package: String,
}

/// Read the crate's layout from `cargo metadata` (no dependency resolution: `--no-deps`).
pub fn layout(dir: &Path, release: bool) -> Result<Layout, String> {
    let metadata = cargo(dir, &["metadata", "--no-deps", "--format-version", "1"])?;
    let parsed: Value = serde_json::from_slice(&metadata).map_err(|error| format!("cargo_metadata_unreadable:{error}"))?;
    let target_dir = parsed["target_directory"].as_str().ok_or_else(|| "cargo_metadata_without_target_directory".to_string())?;
    let package = parsed["packages"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|package| {
            package["manifest_path"].as_str().and_then(|path| Path::new(path).parent()).is_some_and(|parent| same_dir(parent, dir))
        })
        .ok_or_else(|| format!("no_package_in:{}", dir.display()))?;
    let cdylib = package["targets"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|target| target["crate_types"].as_array().into_iter().flatten().any(|kind| kind == "cdylib"))
        .ok_or_else(|| "no_cdylib_target: a component is a cdylib (crate-type = [\"cdylib\"])".to_string())?;
    let name = cdylib["name"].as_str().ok_or_else(|| "target_without_name".to_string())?.replace('-', "_");
    let profile = if release { "release" } else { "debug" };
    Ok(Layout {
        target_dir: PathBuf::from(target_dir).join("wasm32-wasip2").join(profile),
        wasm: PathBuf::from(target_dir).join("wasm32-wasip2").join(profile).join(format!("{name}.wasm")),
        package: package["name"].as_str().unwrap_or_default().to_string(),
    })
}


/// Two paths name the same directory: `cargo metadata` answers with canonical paths, and the caller
/// has whatever the command line gave it (`../wa-fake-kernel/fixture`, a symlink, a `/c/...` path
/// from Git Bash). Compared canonically so the lookup cannot miss for spelling.
fn same_dir(a: &Path, b: &Path) -> bool {
    let canonical = |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    canonical(a) == canonical(b)
}

/// `cargo build --target wasm32-wasip2 [--release]` in `dir`, timed.
pub fn build(dir: &Path, release: bool) -> Result<Built, String> {
    let layout = layout(dir, release)?;
    let mut args = vec!["build", "--target", "wasm32-wasip2"];
    if release {
        args.push("--release");
    }
    let began = Instant::now();
    cargo(dir, &args)?;
    let millis = began.elapsed().as_millis() as u64;
    let bytes = std::fs::metadata(&layout.wasm).map_err(|error| format!("artifact_missing:{}:{error}", layout.wasm.display()))?.len();
    Ok(Built { wasm: layout.wasm, millis, bytes })
}

/// Run cargo in `dir`. The output is captured so a failed build can be reported without the caller
/// having to look at the terminal, and so a successful one does not flood a dev loop's output.
fn cargo(dir: &Path, args: &[&str]) -> Result<Vec<u8>, String> {
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".into());
    let output = Command::new(&cargo)
        .args(args)
        .current_dir(dir)
        .output()
        .map_err(|error| format!("cargo_unavailable:{cargo}:{error}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // The last few lines carry the compiler's own complaint; the whole log is too big to quote.
        let tail: String = stderr.lines().rev().take(6).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join("\n");
        return Err(format!("build_failed:{}:{tail}", output.status));
    }
    Ok(output.stdout)
}
