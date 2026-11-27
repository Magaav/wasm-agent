// Compile the vendored ffmpeg sources for the component's target, into one static archive the cdylib links.
//
// The tree under `vendor/ffmpeg` is exactly what `scripts/vendor-ffmpeg-source.sh` copied from a configured
// build: every .c the build compiled, the generated registry files, the headers, and that build's `config.h`.
// `config.h` is the configuration - the demuxers, decoders and filters this component has, and the fact that
// asm and threads are off - so nothing here re-derives it.
use std::path::{Path, PathBuf};

fn c_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            c_files(&path, out);
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("c") {
            out.push(path);
        }
    }
}

fn main() {
    let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("manifest dir")).join("vendor/ffmpeg");
    // The vendored tree says which sources are COMPILED (`compiled.txt`, written by
    // scripts/vendor-ffmpeg-source.sh): some of the .c beside them are INCLUDED textually and compiling one
    // of those on its own produces a page of nonsense errors, which is how this was learned.
    let mut sources = Vec::new();
    let list = root.join("compiled.txt");
    if list.is_file() {
        for line in std::fs::read_to_string(&list).unwrap_or_default().lines() {
            let line = line.trim();
            if !line.is_empty() { sources.push(root.join(line)); }
        }
    }
    if sources.is_empty() {
        for library in ["libavutil", "libswresample", "libswscale", "libavcodec", "libavformat"] {
            c_files(&root.join(library), &mut sources);
        }
    }
    if sources.is_empty() {
        panic!("no vendored ffmpeg sources under {}: run scripts/vendor-ffmpeg-source.sh", root.display());
    }
    sources.sort();
    let mut build = cc::Build::new();
    build.include(&root).define("HAVE_AV_CONFIG_H", None).define("_GNU_SOURCE", None);
    // ffmpeg's sources are warning-clean for its own flags, not for clang's full set, and a component build
    // that fails on a warning is a build nobody can regenerate.
    build.warnings(false);
    build.flag_if_supported("-w");
    for source in &sources {
        build.file(source);
        println!("cargo:rerun-if-changed={}", source.display());
    }
    build.compile("ffmpeg_vendored");
    println!("cargo:rerun-if-changed={}", root.join("config.h").display());
}
