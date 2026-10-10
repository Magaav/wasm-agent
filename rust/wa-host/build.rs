// Compile the vendored Lua 5.4 C sources into a static library.
fn main() {
    println!("cargo:rerun-if-changed=vendor/lua");
    // The Lua core is embedded with include_str!, so a change to lua/core must rebuild this crate or the
    // binary keeps the core it was last built with. It did not, and the consequence is the one this project
    // keeps paying for: a deploy ships a fix that is not in the artifact. Presence is not freshness.
    generate_embedded();
    // Lua's configuration is selected by defines, and the platform matters:
    // LUA_USE_LINUX pulls in LUA_USE_POSIX, which switches the error handling to
    // _setjmp/_longjmp. mingw-w64 declares `_setjmp(jmp_buf, void *)` - two
    // arguments - so on Windows that does not compile at all. Let Windows use
    // the portable setjmp/longjmp path instead.
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let mut build = cc::Build::new();
    build.include("vendor/lua");
    if target_os == "linux" {
        build.define("LUA_USE_LINUX", None);
    }
    build.warnings(false);
    for entry in std::fs::read_dir("vendor/lua").expect("vendor/lua") {
        let path = entry.expect("entry").path();
        if path.extension().and_then(|e| e.to_str()) != Some("c") {
            continue;
        }
        let name = path.file_stem().unwrap().to_string_lossy().to_string();
        // lua.c / luac.c are the standalone interpreters; onelua.c is a bundler.
        if name == "lua" || name == "luac" || name == "onelua" {
            continue;
        }
        build.file(path);
    }
    build.compile("lua");
    // libm and libdl are Unix libraries; on Windows the C runtime provides both.
    if target_os != "windows" {
        println!("cargo:rustc-link-lib=m");
        println!("cargo:rustc-link-lib=dl");
    }
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
