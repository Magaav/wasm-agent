// Compiles wa-host's vendored Lua 5.4 + glue.c with wasi-sdk's clang (CC_wasm32_wasip2) and links
// wasi-sdk's libsetjmp: Lua's error recovery (pcall) needs setjmp/longjmp, which wasm provides through
// the exception-handling proposal (-mllvm -wasm-enable-sjlj, new EH).
fn main() {
    let lua = std::path::Path::new(&std::env::var("LUA_SRC").expect("LUA_SRC = path to rust/wa-host/vendor/lua")).to_path_buf();
    let sysroot = std::env::var("WASI_SYSROOT").expect("WASI_SYSROOT = <wasi-sdk>/share/wasi-sysroot");
    let mut build = cc::Build::new();
    build.include(&lua).warnings(false).opt_level(2)
        .define("l_signalT", "int") // lstate.h would include <signal.h>, which WASI lacks
        .define("l_randomizePivot()", "0") // ltablib.c would call clock(), absent from the bundled wasi-libc
        .flag("-mllvm").flag("-wasm-enable-sjlj")
        .flag("-mllvm").flag("-wasm-use-legacy-eh=false")
        .flag(&format!("--sysroot={sysroot}"));
    let skip = ["lua", "luac", "onelua", "linit", "loadlib", "liolib", "loslib"];
    for entry in std::fs::read_dir(&lua).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|e| e.to_str()) != Some("c") { continue; }
        let stem = path.file_stem().unwrap().to_string_lossy().to_string();
        if skip.contains(&stem.as_str()) { continue; }
        build.file(path);
    }
    build.file("glue.c");
    build.compile("lua");
    println!("cargo:rustc-link-search=native={sysroot}/lib/wasm32-wasip2");
    println!("cargo:rustc-link-lib=static=setjmp");
    println!("cargo:rerun-if-changed=glue.c");
}
