// Compile the vendored ffmpeg for the component's target: one archive per library, each compiled with its
// OWN directory first on the include path, then linked in dependency order.
//
// WHY PER LIBRARY AND NOT ONE ARCHIVE. ffmpeg's sources include headers BARE (`#include "internal.h"`,
// `#include "adts_header.h"`), and several libraries have a header with the same name doing different
// things: libavcodec/internal.h defines `AVCodecInternal`, libavutil/internal.h does not. With one global
// include order, libavcodec/opus/parse.c found libavutil's and failed with "incomplete definition of type
// struct AVCodecInternal" - a message that names the file and not the cause. ffmpeg's own build passes each
// library's directory first for that library's files; this does the same.
//
// The sources themselves are exactly the list the vendored tree carries (`compiled.txt`, written by
// scripts/vendor-ffmpeg-source.sh): some .c beside them are INCLUDED textually and compiling one of those on
// its own produces a page of nonsense errors.
use std::path::{Path, PathBuf};

/// Dependency order: avformat on top, avutil at the bottom.
const LIBRARIES: [&str; 5] = ["libavutil", "libswresample", "libswscale", "libavcodec", "libavformat"];

fn main() {
    let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("manifest dir")).join("vendor/ffmpeg");
    let list = root.join("compiled.txt");
    let text = std::fs::read_to_string(&list).unwrap_or_else(|error| {
        panic!("no vendor list at {}: run scripts/vendor-ffmpeg-source.sh ({error})", list.display())
    });
    let mut sources: Vec<PathBuf> = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(|line| root.join(line))
        .collect();
    sources.sort();
    if sources.is_empty() {
        panic!("the vendored list is empty: run scripts/vendor-ffmpeg-source.sh");
    }
    for library in LIBRARIES {
        let files: Vec<&PathBuf> = sources.iter().filter(|path| path.starts_with(root.join(library))).collect();
        if files.is_empty() {
            continue;
        }
        let mut build = cc::Build::new();
        build.include(root.join(library));
        build.include(&root);
        for other in LIBRARIES {
            if other != library {
                build.include(root.join(other));
            }
        }
        // wasi-libc hides `struct tm` and `gmtime_r` behind the POSIX/XOPEN feature macros: without them
        // libavutil/dict.c sees an incomplete `struct tm` and a missing `gmtime_r`, which reads like a
        // broken header rather than a missing -D.
        build.define("HAVE_AV_CONFIG_H", None).define("_GNU_SOURCE", None);
        build.define("_POSIX_C_SOURCE", "200809L").define("_XOPEN_SOURCE", "700");
        build.define("_DEFAULT_SOURCE", None);
        build.warnings(false);
        build.flag_if_supported("-w");
        for file in &files {
            build.file(file);
            println!("cargo:rerun-if-changed={}", file.display());
        }
        build.compile(&format!("ffmpeg_{library}"));
    }
    println!("cargo:rustc-link-lib=static=ffmpeg_libavformat");
    println!("cargo:rustc-link-lib=static=ffmpeg_libavcodec");
    println!("cargo:rustc-link-lib=static=ffmpeg_libswscale");
    println!("cargo:rustc-link-lib=static=ffmpeg_libswresample");
    println!("cargo:rustc-link-lib=static=ffmpeg_libavutil");

    // Bindings from the vendored headers. `LIBCLANG_PATH` is the wasi-sdk's own libclang when the environment
    // does not name another: the compiler that builds the C is the one that reads its declarations.
    if std::env::var_os("LIBCLANG_PATH").is_none() {
        let candidate = PathBuf::from("/home/victor/wasm-agent/toolchain/wasi-sdk-34/lib");
        if candidate.is_dir() {
            std::env::set_var("LIBCLANG_PATH", candidate);
        }
    }
    let bindings = bindgen::Builder::default()
        .header(root.join("libavformat/avformat.h").display().to_string())
        .header(root.join("libavcodec/avcodec.h").display().to_string())
        .clang_arg(format!("-I{}", root.display()))
        .clang_arg(format!("-I{}", root.join("libavcodec").display()))
        .allowlist_function("av_.*")
        .allowlist_type("AV.*")
        .allowlist_var("AV.*")
        .layout_tests(false)
        .generate()
        .expect("bindgen could not read the vendored ffmpeg headers");
    let out = PathBuf::from(std::env::var("OUT_DIR").expect("out dir")).join("bindings.rs");
    bindings.write_to_file(&out).expect("writing bindings");
    println!("cargo:rerun-if-changed={}", list.display());
}
