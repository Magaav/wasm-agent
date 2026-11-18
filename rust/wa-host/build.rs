// Build the binary its own embedded data. The vendored Lua 5.4 C sources moved with `lua.rs` to
// `wa-host-support/build.rs`, and the pinned code-mode assets moved with `quickjs.rs` to
// `wa-capabilities/build.rs`: the crate that embeds them provisions them, so a library test binary links
// or checks what it declares. This script keeps the embedded Lua tree, which only the binary reads, and
// the build identity the binary reports as its own.
fn main() {
    // The Lua core is embedded with include_str!, so a change to lua/core must rebuild this crate or the
    // binary keeps the core it was last built with. It did not, and the consequence is the one this project
    // keeps paying for: a deploy ships a fix that is not in the artifact. Presence is not freshness.
    generate_embedded();
    // ...and the binary carries its own build identity (commit, tree, dirty, the commits it contains), so
    // "which commit is this binary?" is answered by the binary and never by a script's guess.
    // MEASURED 18/11: the node on `work` ran a build of 8 commits that were on no landed branch, and its
    // installed.txt said commit=14963b6f - the record was a caller's belief, and the belief was wrong.
    generate_build_info();
}

// Directory tracking catches additions/removals; include_str! tracks content changes.
fn generate_embedded() {
    let root = std::path::PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap())
        .join("../..").canonicalize().expect("repository root");
    let mut paths = vec![root.join("AGENTS.orchestrator.md"), root.join("AGENTS.subagents.md")];
    fn collect(dir: &std::path::Path, paths: &mut Vec<std::path::PathBuf>) {
        println!("cargo:rerun-if-changed={}", dir.display());
        for entry in std::fs::read_dir(dir).expect("Lua directory") {
            let path = entry.expect("Lua entry").path();
            if path.is_dir() { collect(&path, paths); }
            else if matches!(path.extension().and_then(|s| s.to_str()), Some("lua" | "sql")) {
                paths.push(path);
            }
        }
    }
    collect(&root.join("lua/core"), &mut paths);
    collect(&root.join("lua/vendor"), &mut paths);
    paths.sort();
    let mut source = String::from("const EMBEDDED: &[(&str, &str)] = &[\n");
    for path in paths {
        let name = path.strip_prefix(&root).unwrap().to_str().unwrap().replace('\\', "/");
        let absolute = path.to_str().unwrap().replace('\\', "/");
        source.push_str(&format!("    ({name:?}, include_str!({absolute:?})),\n"));
    }
    source.push_str("];\n");
    std::fs::write(std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap()).join("embedded.rs"), source)
        .expect("write embedded registry");
}

// ---- the build identity --------------------------------------------------------------------------
//
// WHY IT IS EMBEDDED AND NOT WRITTEN BESIDE THE BINARY. A file next to a binary is written by whoever
// installed it, and that is a claim; the binary answering for itself is the fact. The two came apart on
// 18/11: an install record said commit=14963b6f while the bytes were a build of 8 commits that were on no
// landed branch. So the answer to "which commit is this?" is compiled in, and every install path reads it
// back out of the binary instead of writing down what it meant to install.
//
// The stampers that already exist (scripts/publish-node-binaries.sh, scripts/lib/fast-binary.sh,
// scripts/codemode-build.mjs) pass WA_BUILD_SOURCE_COMMIT/WA_BUILD_SOURCE_TREE: a build made in a tree that
// is not that commit's checkout (a cross build, a rebuilt snapshot) says so, and source=env records that
// the commit came from the caller. Absent them, git in this checkout is the answer.
fn generate_build_info() {
    use std::process::Command;
    let root = std::path::PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap())
        .join("../..").canonicalize().expect("repository root");
    // A new commit moves the ref HEAD points at, not .git/HEAD: without these the crate keeps the identity
    // of whatever commit was checked out when it was last built, which is the stale-artifact failure the
    // embedded Lua tree had.
    for path in [".git/HEAD", ".git/index"] {
        println!("cargo:rerun-if-changed={}", root.join(path).display());
    }
    if let Ok(head) = std::fs::read_to_string(root.join(".git/HEAD")) {
        if let Some(reference) = head.trim().strip_prefix("ref:") {
            let reference = reference.trim();
            println!("cargo:rerun-if-changed={}", root.join(".git").join(reference).display());
            println!("cargo:rerun-if-changed={}", root.join(".git/packed-refs").display());
        }
    }
    println!("cargo:rerun-if-env-changed=WA_BUILD_SOURCE_COMMIT");
    println!("cargo:rerun-if-env-changed=WA_BUILD_SOURCE_TREE");

    // A git run that SUCCEEDED, with its stdout trimmed - which may legitimately be empty. The distinction
    // matters and was measured by scripts/test-build-info.sh: `git status --porcelain` on a CLEAN tree prints
    // nothing, and reading "no output" as "the command failed" made every clean build report dirty=unknown.
    let git_raw = |arguments: &[&str]| -> Option<String> {
        let output = Command::new("git").arg("-C").arg(&root).args(arguments).output().ok()?;
        if !output.status.success() { return None; }
        Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
    };
    let git = |arguments: &[&str]| -> Option<String> {
        git_raw(arguments).filter(|text| !text.is_empty())
    };
    // A hash is only a hash: 40 or 64 lowercase hex, and nothing else may reach a record whose checks
    // compare it.
    fn full_hash(value: &str) -> bool {
        let value = value.trim();
        matches!(value.len(), 40 | 64) && value.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    }
    let from_env = std::env::var("WA_BUILD_SOURCE_COMMIT").ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
    let commit_source = if from_env.is_some() { "env" } else { "git" };
    let commit = from_env
        .or_else(|| git(&["rev-parse", "HEAD"]))
        .filter(|value| full_hash(value))
        .unwrap_or_default();
    let tree = std::env::var("WA_BUILD_SOURCE_TREE").ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
        .or_else(|| git(&["rev-parse", "HEAD^{tree}"]))
        .filter(|value| full_hash(value))
        .unwrap_or_default();
    // Dirtiness is a fact about the tree this build read, and "unknown" when it cannot be established: a
    // build with no git and no stamp must not claim to be a clean build of anything.
    let dirty = match git_raw(&["status", "--porcelain", "--untracked-files=no"]) {
        Some(changes) => if changes.is_empty() { "false" } else { "true" },
        None => "unknown",
    };
    // Every ancestor, sorted, so `--contains <commit>` is answered inside the binary. A repository's whole
    // history is a few thousand lines of hex; a release bundle that carries it needs no checkout on the
    // node it installs to, which is the case an ancestry guard cannot otherwise answer.
    let mut ancestors: Vec<String> = git(&["rev-list", "HEAD"])
        .map(|list| list.lines().map(|line| line.trim().to_string()).filter(|line| full_hash(line)).collect())
        .unwrap_or_default();
    ancestors.sort();
    ancestors.dedup();
    let complete = !ancestors.is_empty() && ancestors.iter().any(|line| line == &commit);
    let built_epoch = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs()).unwrap_or(0);
    let version = std::env::var("CARGO_PKG_VERSION").unwrap_or_default();
    let mut source = String::from("// Generated by rust/wa-host/build.rs - the binary's own identity.\n");
    source.push_str(&format!("pub const VERSION: &str = {version:?};\n"));
    source.push_str(&format!("pub const COMMIT: &str = {commit:?};\n"));
    source.push_str(&format!("pub const TREE: &str = {tree:?};\n"));
    source.push_str(&format!("pub const DIRTY: &str = {dirty:?};\n"));
    source.push_str(&format!("pub const SOURCE: &str = {commit_source:?};\n"));
    source.push_str(&format!("pub const BUILT_EPOCH: u64 = {built_epoch};\n"));
    source.push_str(&format!("pub const ANCESTORS_COMPLETE: bool = {complete};\n"));
    source.push_str("pub const ANCESTORS: &[&str] = &[\n");
    for ancestor in &ancestors {
        source.push_str(&format!("    {ancestor:?},\n"));
    }
    source.push_str("];\n");
    std::fs::write(std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap()).join("build_info.rs"), source)
        .expect("write build identity");
}
