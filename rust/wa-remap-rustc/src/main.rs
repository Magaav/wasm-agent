//! `RUSTC_WRAPPER` for the component build: takes the *where* out of the artifact, so that the same
//! source builds to the same bytes from any checkout path (docs/COMPONENTS.md, "Reproducible builds:
//! the checkout path is not an input").
//!
//! It only adds `--remap-path-prefix` arguments and then runs the real compiler; it never inspects,
//! rewrites or drops the arguments Cargo built.
//!
//! # Why a compiled shim rather than `scripts/wa-remap-rustc.cmd`
//!
//! A `.cmd`/`.bat` is not executed by Cargo: `CreateProcess` starts `cmd.exe`, which re-parses the
//! whole command line, decides quoting itself, and refuses anything over **8191 characters**
//! ("The command line is too long"). A component crate hands rustc long arguments - `windows-sys`
//! 0.61.2 alone passes one `--check-cfg cfg(feature, values(...))` argument that names its ~250
//! `Win32_*`/`Wdk_*` features - so the `.cmd` twin failed the `wa-whatsapp` build while the small gate
//! components passed (measured on wasm_the_first, main 53292246). `cmd.exe` also expands `%VAR%`,
//! treats `^` and unpaired quotes specially, and cannot pass an empty argument, so even a `.cmd` that
//! used `%*` verbatim would re-parse what Cargo built.
//!
//! An `.exe` is started directly (`CreateProcess`, a 32767-character limit and no quoting layer);
//! `std::process` rebuilds the command line with the same quoting rules Cargo itself used, so every
//! argument arrives byte for byte. On a POSIX host `scripts/wa-remap-rustc` does the same job with
//! `exec` and needs no compile, which is why this binary is only used on Windows.
//!
//! # Why it is installed outside the checkout
//!
//! So that the resolved wrapper path is one string for every checkout: `RUSTC_WRAPPER` is the bare
//! name `wa-remap-rustc`, and `scripts/build-components.sh` installs this binary in a content-addressed
//! directory under the temp dir - one path per wrapper source - and puts that directory first on
//! `PATH`. An input that can be a constant should not be a per-checkout path. (What still keeps a
//! component with a *path dependency* from reproducing byte for byte is Cargo's own `-C metadata`, not
//! this path: docs/COMPONENTS.md, "Reproducible builds", has the measurement.)
//!
//! # Where the roots come from
//!
//! `WA_REMAP_CHECKOUT` and `WA_REMAP_CARGO_HOME` (set by `scripts/build-components.sh`), else the
//! binary's own location (when it sits inside a checkout's `scripts/`). A wrapper that cannot find
//! the tree is loud and exits 2: a `--remap-path-prefix` that matches nothing is silent, and a
//! silent one is a build that only *looks* reproducible.

use std::ffi::OsString;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

/// The fixed names the checkout and the registry cache are rewritten to. They must never change:
/// they are in the bytes of every artifact that repeats them.
const CHECKOUT_AS: &str = "/wasm-build";
const CARGO_HOME_AS: &str = "/cargo-home";

fn main() {
    let argv: Vec<OsString> = std::env::args_os().skip(1).collect();
    let (compiler, rest) = match split_argv(argv) {
        Ok(split) => split,
        Err(message) => fail(&message),
    };

    let checkout = match env_path("WA_REMAP_CHECKOUT").or_else(locate_checkout) {
        Some(path) => path,
        None => fail(
            "cannot tell where the checkout is: set WA_REMAP_CHECKOUT (the wrapper is installed \
             outside the checkout, so its own path says nothing)",
        ),
    };
    if !checkout.join("rust").join("components").is_dir() {
        fail(&format!("not a wasm-agent checkout: {}", checkout.display()));
    }
    let cargo_home = env_path("WA_REMAP_CARGO_HOME").unwrap_or_else(default_cargo_home);

    // Cargo's own rustflags, if any, stay: the wrapper only adds to the command line.
    let mut args = remap_args(&checkout, &cargo_home);
    args.extend(rest);

    run(&compiler, &args);
}

/// Cargo calls a wrapper as `wrapper <rustc> <args...>`; it also calls it with `--rustc` when it asks
/// the wrapper to pick the compiler, so `--rustc` is a compiler request and not a path. The compiler
/// is the first argument, never a source file.
fn split_argv(mut argv: Vec<OsString>) -> Result<(OsString, Vec<OsString>), String> {
    let compiler = match argv.first().cloned() {
        Some(flag) if flag == "--rustc" => OsString::from("rustc"),
        Some(path) => path,
        None => return Err("the wrapper needs the compiler as its first argument".to_string()),
    };
    argv.remove(0);
    Ok((compiler, argv))
}

/// The remap arguments for both roots, in the order rustc accepts and in every spelling the
/// artifacts can carry.
fn remap_args(checkout: &Path, cargo_home: &Path) -> Vec<OsString> {
    let mut args: Vec<OsString> = Vec::new();
    add_remaps(&mut args, checkout, CHECKOUT_AS);
    add_remaps(&mut args, cargo_home, CARGO_HOME_AS);
    args
}

/// Every spelling a source path can take inside an artifact. On Windows a native tool embeds
/// `C:\a\b` (a path dependency's panic locations carry backslashes) while Cargo prints `C:/a/b`, so
/// both are remapped; a prefix that matches nothing is a no-op, which is why both are always passed.
fn add_remaps(args: &mut Vec<OsString>, root: &Path, as_name: &str) {
    let native = root.to_string_lossy().into_owned();
    add_one(args, &native, as_name);
    if cfg!(windows) {
        let mixed = native.replace('\\', "/");
        let windows = mixed.replace('/', "\\");
        add_one(args, &mixed, as_name);
        add_one(args, &windows, as_name);
    }
}

fn add_one(args: &mut Vec<OsString>, from: &str, as_name: &str) {
    if from.is_empty() || from == as_name {
        return;
    }
    let flag = format!("--remap-path-prefix={from}={as_name}");
    // Two spellings can be the same string (a mixed path on a tree that has no backslash path).
    if !args.iter().any(|a| a.to_str() == Some(flag.as_str())) {
        args.push(OsString::from(flag));
    }
}

fn run(compiler: &OsString, args: &[OsString]) -> ! {
    let mut command = Command::new(compiler);
    command.args(args);
    run_or_exec(command)
}

/// On a POSIX host there is no reason for a second process: the wrapper *is* the compiler, so it
/// becomes it. On Windows the child is waited for and its exit code is the wrapper's.
#[cfg(unix)]
fn run_or_exec(mut command: Command) -> ! {
    use std::os::unix::process::CommandExt;
    let program = command.get_program().to_string_lossy().into_owned();
    let error = command.exec();
    fail(&format!("cannot run {program}: {error}"));
}

#[cfg(not(unix))]
fn run_or_exec(mut command: Command) -> ! {
    let program = command.get_program().to_string_lossy().into_owned();
    match command.status() {
        Ok(status) => std::process::exit(status.code().unwrap_or(1)),
        Err(error) => fail(&format!("cannot run {program}: {error}")),
    }
}

/// The checkout of the running wrapper, if it was left in place in a checkout's `scripts/`.
fn locate_checkout() -> Option<PathBuf> {
    let mut dir = std::env::current_exe().ok()?.parent()?.to_path_buf();
    for _ in 0..4 {
        if dir.join("rust").join("components").is_dir() {
            return Some(dir);
        }
        dir = dir.parent()?.to_path_buf();
    }
    None
}

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn default_cargo_home() -> PathBuf {
    if let Some(home) = env_path("CARGO_HOME") {
        return home;
    }
    if cfg!(windows) {
        env_path("USERPROFILE").unwrap_or_default().join(".cargo")
    } else {
        env_path("HOME").unwrap_or_default().join(".cargo")
    }
}

fn fail(message: &str) -> ! {
    // stderr, not stdout: Cargo reads the wrapper's exit status and forwards the compiler's own
    // streams, and a wrapper that explains nothing is a wrapper that hides a broken build.
    let _ = writeln!(std::io::stderr(), "wa-remap-rustc: {message}");
    std::process::exit(2)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flags(checkout: &str, cargo_home: &str) -> Vec<String> {
        remap_args(Path::new(checkout), Path::new(cargo_home))
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect()
    }

    #[test]
    fn both_roots_are_remapped_to_their_fixed_names() {
        let out = flags("/a/tree", "/a/home");
        assert!(
            out.contains(&"--remap-path-prefix=/a/tree=/wasm-build".to_string()),
            "{out:?}"
        );
        assert!(
            out.contains(&"--remap-path-prefix=/a/home=/cargo-home".to_string()),
            "{out:?}"
        );
    }

    #[test]
    fn a_windows_root_is_remapped_in_every_spelling_it_can_have() {
        // The same tree, spelled the way `cygpath -m` prints it (C:/a/b) and the way a native tool
        // embeds it (C:\a\b). Both must be remapped or one of them leaks the path.
        let mixed = if cfg!(windows) { "C:/a/b" } else { "/a/b" };
        let out = flags(mixed, mixed);
        assert!(
            out.iter()
                .filter(|f| f.ends_with("=/wasm-build"))
                .count()
                >= if cfg!(windows) { 2 } else { 1 },
            "{out:?}"
        );
        if cfg!(windows) {
            assert!(
                out.contains(&r"--remap-path-prefix=C:\a\b=/wasm-build".to_string()),
                "{out:?}"
            );
            assert!(
                out.contains(&r"--remap-path-prefix=C:\a\b=/cargo-home".to_string()),
                "{out:?}"
            );
        }
    }

    #[test]
    fn no_duplicate_or_self_remap_is_passed() {
        // A root that is already spelled with backslashes yields the same string twice; a root that
        // is already the fixed name must not be remapped onto itself.
        let backslashed = if cfg!(windows) { r"C:\a\b" } else { "/a/b" };
        let out = flags(backslashed, backslashed);
        let mut sorted = out.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), out.len(), "duplicate flag in {out:?}");

        let self_named = flags(CHECKOUT_AS, CARGO_HOME_AS);
        assert!(
            !self_named.iter().any(|f| f.contains("=/wasm-build=/wasm-build")),
            "{self_named:?}"
        );
        assert!(
            !self_named
                .iter()
                .any(|f| f.contains("=/cargo-home=/cargo-home")),
            "{self_named:?}"
        );
    }

    #[test]
    fn rustc_is_the_first_argument_unless_cargo_asks_for_a_compiler() {
        let (compiler, rest) =
            split_argv(vec![OsString::from("/t/rustc"), OsString::from("--version")]).unwrap();
        assert_eq!(compiler, OsString::from("/t/rustc"));
        assert_eq!(rest, vec![OsString::from("--version")]);

        // `--rustc` is Cargo asking the wrapper to pick the compiler, not a compiler path.
        let (compiler, rest) =
            split_argv(vec![OsString::from("--rustc"), OsString::from("--version")]).unwrap();
        assert_eq!(compiler, OsString::from("rustc"));
        assert_eq!(rest, vec![OsString::from("--version")]);
    }

    #[test]
    fn a_wrapper_called_without_a_compiler_is_loud() {
        assert!(split_argv(Vec::new()).is_err());
    }
}
