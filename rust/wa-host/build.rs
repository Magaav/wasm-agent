// Compile the vendored Lua 5.4 C sources into a static library.
fn main() {
    println!("cargo:rerun-if-changed=vendor/lua");
    // The Lua core is embedded with include_str!, so a change to lua/core must rebuild this crate or the
    // binary keeps the core it was last built with. It did not, and the consequence is the one this project
    // keeps paying for: a deploy ships a fix that is not in the artifact. Presence is not freshness.
    generate_embedded();
    generate_codemode_assets();
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

// Build-time only: prepared, integrity-pinned assets may be embedded for an offline,
// Node-free runtime. No downloader or package manager runs in the production host.
//
// An empty embed is not a neutral default. `WASM_AGENT_CODEMODE=native` is the shipped default, and a
// binary built without these bytes starts every run with `codemode_not_ready` before its first model
// call, leaving the conversation silent (measured 2026-10-22: `on-stale.sh` rebuilt with plain
// `cargo build`, installed it, and every turn failed). So a host release build that is not explicitly
// exempted refuses to produce an artifact it cannot honour. Exemptions are named, never ambient:
//
//   WA_CODEMODE_BUILD_ASSETS=<dir>  build with these verified assets (the shipping path)
//   WA_CODEMODE_ALLOW_EMPTY=1      this artifact is not meant to run code mode (gate/cross builds)
fn generate_codemode_assets() {
    println!("cargo:rerun-if-env-changed=WA_CODEMODE_BUILD_ASSETS");
    println!("cargo:rerun-if-env-changed=WA_CODEMODE_ALLOW_EMPTY");
    let out = std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    let dir = std::env::var_os("WA_CODEMODE_BUILD_ASSETS").map(std::path::PathBuf::from);
    let allow_empty = std::env::var("WA_CODEMODE_ALLOW_EMPTY").map(|v| v == "1").unwrap_or(false);
    let host = std::env::var("HOST").unwrap_or_default();
    let target = std::env::var("TARGET").unwrap_or_default();
    // A cross build is not the artifact this platform serves; it stays allowed to build without the
    // runtime so Android and packaging lanes do not silently acquire a host dependency. Host releases
    // are the case that reaches operators, and they fail by name instead. Debug/test profiles are not
    // shippable, so they stay cheap: a `cargo test` must not need a provisioned asset directory.
    let cross = !host.is_empty() && !target.is_empty() && host != target;
    let release = std::env::var("PROFILE").map(|profile| profile == "release").unwrap_or(false);
    let enforce = release && !cross && !allow_empty;
    for name in ["quickjs.wasm", "prelude.js"] {
        let bytes = match &dir {
            Some(dir) => {
                let path = dir.join(name);
                println!("cargo:rerun-if-changed={}", path.display());
                std::fs::read(&path)
                    .unwrap_or_else(|error| panic!("code-mode asset {} unreadable: {error}", path.display()))
            }
            None if !enforce => Vec::new(),
            None => panic!(
                "code-mode assets required: set WA_CODEMODE_BUILD_ASSETS to a prepared, verified asset \
                 directory (scripts/codemode-build.mjs build does this), or set WA_CODEMODE_ALLOW_EMPTY=1 \
                 for an artifact that is not meant to run code mode"
            ),
        };
        if bytes.is_empty() && enforce {
            panic!("code-mode asset {name} is empty; refusing to embed a native-default binary that cannot run code mode");
        }
        if !bytes.is_empty() && name.ends_with(".wasm") && !bytes.starts_with(b"\0asm") {
            panic!("code-mode asset {name} is not a WebAssembly module; provision and verify it first");
        }
        std::fs::write(out.join(name), bytes).expect("write code-mode build asset");
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
