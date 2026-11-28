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
use std::path::PathBuf;

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
        // -iquote, NOT -I, for the library directories: -I is used for angle-bracket includes too, and
        // libavutil contains a `time.h` of ffmpeg's own. With -I on that directory, `#include <time.h>` in
        // libavutil/dict.c resolved to ffmpeg's header instead of wasi-libc's, so `struct tm` was incomplete,
        // `gmtime_r` and `strftime` were undeclared, and the build failed three files from the real cause.
        // Measured, not guessed: the same file compiles with `-I.` (ffmpeg's own build) and fails with
        // `-I libavutil` - the difference is exactly this flag. -iquote reaches quoted includes only.
        build.include(&root);
        build.flag(format!("-iquote{}", root.join(library).display()));
        for other in LIBRARIES {
            if other != library {
                build.flag(format!("-iquote{}", root.join(other).display()));
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

    // The struct fields are read in C (native/ffmpeg_access.c), so the Rust side needs no offsets and no
    // generated bindings: see src/ffi.rs for the measurement that made bindgen unusable here.
    {
        let native = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("manifest dir")).join("native");
        let mut access = cc::Build::new();
        access.include(&root);
        for library in LIBRARIES {
            access.flag(format!("-iquote{}", root.join(library).display()));
        }
        access.warnings(false);
        access.flag_if_supported("-w");
        access.file(native.join("ffmpeg_access.c"));
        // wasi-libc on wasm32-wasip2 has no `clock`, and libavutil/random_seed.c calls it.
        access.file(native.join("wasi_compat.c"));
        access.file(native.join("ffmpeg_frames.c"));
        access.compile("ffmpeg_access");
        println!("cargo:rustc-link-lib=static=ffmpeg_access");
        println!("cargo:rerun-if-changed={}", native.join("ffmpeg_access.c").display());
        println!("cargo:rerun-if-changed={}", native.join("wasi_compat.c").display());
        println!("cargo:rerun-if-changed={}", native.join("ffmpeg_frames.c").display());
    }
    println!("cargo:rerun-if-changed={}", list.display());
}
