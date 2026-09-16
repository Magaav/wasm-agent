// Compile the vendored Lua 5.4 C sources into a static library.
fn main() {
    println!("cargo:rerun-if-changed=vendor/lua");
    let mut build = cc::Build::new();
    build.include("vendor/lua");
    build.define("LUA_USE_LINUX", None);
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
    println!("cargo:rustc-link-lib=m");
    println!("cargo:rustc-link-lib=dl");
}
