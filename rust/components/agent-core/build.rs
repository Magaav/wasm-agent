// Compiles wa-host's vendored Lua 5.4 (all of it, io/os/package included, as the native
// interpreter's luaL_openlibs has them) + glue.c with wasi-sdk's clang (CC_wasm32_wasip2) and links
// wasi-sdk's libsetjmp: Lua's error recovery (pcall) uses setjmp/longjmp, which wasm provides
// through the exception-handling proposal (-mllvm -wasm-enable-sjlj, new EH).
fn main() {
    let manifest = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let lua = std::env::var("LUA_SRC")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| manifest.join("../../wa-host-support/vendor/lua"));
    let sysroot = std::env::var("WASI_SYSROOT").expect("WASI_SYSROOT = <wasi-sdk>/share/wasi-sysroot");
    let mut build = cc::Build::new();
    build.include(&lua).warnings(false).opt_level(2)
        .define("l_signalT", "int") // lstate.h would include <signal.h>, which WASI lacks
        .define("l_randomizePivot()", "0") // ltablib.c: no need for clock() in sort pivots
        .define("l_system(cmd)", "((cmd) == NULL ? 0 : -1)") // no processes in WASI: os.execute fails
        .define("LUA_TMPNAMBUFSIZE", "32")
        .define("lua_tmpnam(b,e)", "{ b[0] = 0; e = 1; }") // no tmpnam in wasi-libc: os.tmpname fails
        .define("_WASI_EMULATED_PROCESS_CLOCKS", None) // os.clock
        .flag("-mllvm").flag("-wasm-enable-sjlj")
        .flag("-mllvm").flag("-wasm-use-legacy-eh=false")
        .flag(&format!("--sysroot={sysroot}"));
    for entry in std::fs::read_dir(&lua).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|e| e.to_str()) != Some("c") { continue; }
        let stem = path.file_stem().unwrap().to_string_lossy().to_string();
        // the standalone interpreters and the one-file bundler
        if ["lua", "luac", "onelua"].contains(&stem.as_str()) { continue; }
        build.file(path);
    }
    build.file("glue.c");
    build.compile("lua");
    println!("cargo:rustc-link-search=native={sysroot}/lib/wasm32-wasip2");
    println!("cargo:rustc-link-lib=static=setjmp");
    println!("cargo:rustc-link-lib=static=wasi-emulated-process-clocks");
    println!("cargo:rerun-if-changed=glue.c");
    println!("cargo:rerun-if-env-changed=LUA_SRC");
}
