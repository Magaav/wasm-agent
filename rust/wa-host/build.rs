// Build the binary its own embedded data. The vendored Lua 5.4 C sources moved with `lua.rs` to
// `wa-host-support/build.rs`, and the pinned code-mode assets moved with `quickjs.rs` to
// `wa-capabilities/build.rs`: the crate that embeds them provisions them, so a library test binary links
// or checks what it declares. This script keeps the embedded Lua tree, which only the binary reads.
fn main() {
    // The Lua core is embedded with include_str!, so a change to lua/core must rebuild this crate or the
    // binary keeps the core it was last built with. It did not, and the consequence is the one this project
    // keeps paying for: a deploy ships a fix that is not in the artifact. Presence is not freshness.
    generate_embedded();
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
