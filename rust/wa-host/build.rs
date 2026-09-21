// Compile the vendored Lua 5.4 C sources into a static library.
fn main() {
    println!("cargo:rerun-if-changed=vendor/lua");
    // The Lua core is embedded with include_str!, so a change to lua/core must rebuild this crate or the
    // binary keeps the core it was last built with. It did not, and the consequence is the one this project
    // keeps paying for: a deploy ships a fix that is not in the artifact. Presence is not freshness.
    println!("cargo:rerun-if-changed=../../lua/core");
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
