//! Lua's policy stays in Lua; process ownership and cancellation stay outside its interpreter.
use serde_json::{json, Value};
use std::{sync::OnceLock, time::Duration};
use wa_operation::{Manager, Spec};

/// The kernel's vault, opened on first use and kept for the life of the process. A FAILED open is not
/// kept: this slot used to be a OnceLock of an Option, so the first None - a keystore created a moment
/// later, a policy file the operator fixed, a keyring that became available - was cached as "no vault
/// here" for the rest of the process, and every connector naming a vault_env entry answered
/// vault_unavailable until the node restarted. The slot now holds a vault only when there is one, so
/// a launch retries an open that failed and a node that recovers needs no restart.
static VAULT: std::sync::Mutex<Option<wa_kernel_runtime::vault_host::VaultService>> = std::sync::Mutex::new(None);

/// Fill the slot with open() if it is empty, and say whether it holds something. The opener is a
/// parameter so the retry rule is testable without a vault: a failure is tried again on the next
/// call, a success is not re-opened.
fn ensure_cached<T>(slot: &std::sync::Mutex<Option<T>>, open: impl FnOnce() -> Option<T>) -> bool {
    let mut guard = match slot.lock() { Ok(guard) => guard, Err(poisoned) => poisoned.into_inner() };
    if guard.is_none() { *guard = open(); }
    guard.is_some()
}

/// One vault entry's value for a child's environment. The entry NAME travels through Lua and the
/// definition; the value is put in the child's environment here and never returned to the
/// interpreter, a request file or a transcript.
///
/// It opens the slot through `ensure_cached`, the one function the retry rule is tested on. This
/// function used to carry its own copy of that rule, so `vault_cache_tests` proved something about a
/// helper the launch path never called (review, 19/11). One rule, one function - and the test that
/// runs the launch path itself is `the_launch_path_opens_the_vault_through_the_one_retry_rule`.
fn vault_value(entry: &str) -> Result<String, String> {
    vault_value_with(&VAULT, || wa_kernel_runtime::vault_host::VaultService::from_env().ok(), |service| {
        service.use_by_ref(entry).map(|value| value.to_string())
            .ok_or_else(|| format!("vault_entry_missing:{entry}: store it with `wa vault set {entry} --stdin`"))
    })
}

/// The launch path's vault read, with its opener and its lookup injected, so the retry rule is tested
/// on the function that injects the value and not on a helper beside it: a failed open is not
/// remembered (the vault may be created a moment later) and an open vault is not reopened.
fn vault_value_with<T>(slot: &std::sync::Mutex<Option<T>>, open: impl FnOnce() -> Option<T>,
                       read: impl FnOnce(&T) -> Result<String, String>) -> Result<String, String> {
    if !ensure_cached(slot, open) {
        return Err("vault_unavailable: this node's vault does not open (wa vault status)".into());
    }
    let guard = match slot.lock() { Ok(guard) => guard, Err(poisoned) => poisoned.into_inner() };
    let service = guard.as_ref()
        .ok_or("vault_unavailable: this node's vault does not open (wa vault status)")?;
    read(service)
}

// ---- the approval a connector that names a vault entry carries -------------------------------
//
// (docs/VAULT.md, 18/11.) A `vault_env` definition is the operator's, and the approval is a digest over
// what the launch IS: the program, the directory it runs in, its arguments, the plain environment it
// asks for, EVERY file it can run or load (v3: the closure of what those files import in turn, the
// interpreter the launch spawns, and every argument resolved from the connector's own directory) and the
// vault names it asks for. Until this existed the approval was one boolean in memory.db while
// the scripts it runs live in a directory the agent can write, so an approved connector's script could
// be replaced afterwards and the value handed to the new code. The digest is recomputed HERE, from the
// bytes on disk, immediately before a value is read; a mismatch refuses the launch.
//
// The canonical text is shared with `lua/core/mcp.lua` (`M.vault_approval_text`): one form, two
// implementations, and each side's tests pin the same digest of the same fixture. Every field is
// percent-escaped (a `%` and two uppercase hex digits for any byte outside [A-Za-z0-9._~/:@+,=-]) so a
// newline, a space or a tab inside an argument cannot forge a line.
fn approval_field(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        let keep = byte.is_ascii_alphanumeric()
            || matches!(byte, b'.' | b'_' | b'~' | b'/' | b':' | b'@' | b'+' | b',' | b'=' | b'-');
        if keep { out.push(byte as char) } else { out.push_str(&format!("%{byte:02X}")) }
    }
    out
}

/// The form of the canonical text. A row approved under an older one is refused rather than compared
/// against a digest it could never match: v2 added the launch's directory and its plain (non-vault)
/// environment, and v3 adds the interpreter the launch spawns and the arguments resolved from its own
/// directory; the file list is the CLOSURE of the code the connector loads.
const APPROVAL_FORM: &str = "mcp-vault-approval/v4";

fn approval_text(program: &str, cwd: &str, env: &[(String, String)], args: &[String],
                 files: &[(String, String)], vault: &[String], native: Option<(&str, &str)>) -> String {
    let mut text = format!("{APPROVAL_FORM}\n");
    text.push_str(&format!("program {}\n", approval_field(program)));
    text.push_str(&format!("cwd {}\n", approval_field(cwd)));
    // Sorted by name, so the digest says the same thing whatever order a caller built the list in.
    let mut ordered = env.to_vec();
    ordered.sort();
    for (name, reference) in ordered {
        text.push_str(&format!("env {}\n", approval_field(&format!("{name}={reference}"))));
    }
    for arg in args { text.push_str(&format!("arg {}\n", approval_field(arg))); }
    for (path, sha) in files { text.push_str(&format!("file {} {}\n", approval_field(path), sha.to_lowercase())); }
    // The operator's own voucher for a native binary (/mcp <id> on --native): one line, only when one was
    // recorded, so a connector approved without one hashes to the text it always did.
    if let Some((path, sha)) = native {
        text.push_str(&format!("native {} {}\n", approval_field(path), sha.to_lowercase()));
    }
    for name in vault { text.push_str(&format!("vault {}\n", approval_field(name))); }
    text
}

fn sha256_hex(bytes: &[u8]) -> String {
    use ring::digest::{digest, SHA256};
    digest(&SHA256, bytes).as_ref().iter().map(|byte| format!("{byte:02x}")).collect()
}

/// An absolute path whose extension says it is a script: the launch's own arguments the approval must
    // `\` and `"` escape to two units, so a quote-heavy command reaches the bound sooner.
fn is_script_path(value: &str) -> bool {
    const SCRIPTS: [&str; 11] = ["mjs", "cjs", "js", "lua", "sh", "bash", "py", "rb", "pl", "ps1", "bat"];
    let bytes = value.as_bytes();
    let absolute = value.starts_with('/')
        || (bytes.len() > 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':'
            && (bytes[2] == b'\\' || bytes[2] == b'/'));
    if !absolute { return false; }
    std::path::Path::new(value).extension().and_then(|ext| ext.to_str())
        .is_some_and(|ext| SCRIPTS.iter().any(|known| ext.eq_ignore_ascii_case(known)))
}

// ---- the shapes whose coverage cannot be proven ------------------------------------------------
//
// (This round's second hole.) The digest used to hash "an absolute argument with a script extension" plus
// the runtime, so a relative 'conn.mjs' (which node resolves from the cwd), an extensionless program
// ('~/bin/conn'), a package runner ('npx', 'uvx') and every imported module were code the approval never
// named. The console refuses to APPROVE such a connector (lua/core/mcp.lua, M.vault_manifest's
// 'problems'); the same shapes are refused here, from the bytes on disk, so an approval that predates
// the rule cannot launch either.
const PLATFORM_ROOTS: [&str; 15] = ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/lib/",
    "/usr/lib64/", "/usr/libexec/", "/lib/", "/lib64/", "/usr/local/bin/", "/usr/local/sbin/",
    "/opt/homebrew/", "/nix/store/", "/snap/", "/System/"];
const PACKAGE_RUNNERS: [&str; 8] = ["npx", "uvx", "bunx", "pipx", "npm", "pnpm", "yarn", "corepack"];
const SCRIPT_EXTENSIONS: [&str; 11] = ["mjs", "cjs", "js", "lua", "sh", "bash", "py", "rb", "pl", "ps1", "bat"];

fn is_absolute_path(value: &str) -> bool {
    let bytes = value.as_bytes();
    value.starts_with('/')
        || (bytes.len() > 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':'
            && (bytes[2] == b'\\' || bytes[2] == b'/'))
}

fn basename(path: &str) -> String {
    path.rsplit(['/', '\\']).next().unwrap_or(path).to_lowercase()
}

/// A program under one of these is a CANDIDATE for being the platform's (the interpreter the connector
/// runs ON), not the connector's own code: /usr/bin/node is replaced by a package manager, never by the
/// agent. A prefix alone is not the answer - see platform_owned below.
fn platform_root(path: &str) -> bool {
    let normalized = path.replace('\\', "/").to_lowercase();
    PLATFORM_ROOTS.iter().any(|root| normalized.starts_with(root))
}

/// The directory above a normalized absolute path.
fn parent_of(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rfind('/') {
        Some(0) => "/".into(),
        Some(index) => trimmed[..index].to_string(),
        None => String::new(),
    }
}

/// Root-owned and not group/other-writable: what a package manager's upgrade leaves behind. On a host
/// with no uid to read (Windows) the prefix rule is the answer, and docs/VAULT.md says so.
fn owned_by_root(path: &str) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else { return false };
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.uid() != 0 { return false; }
        if metadata.mode() & 0o022 != 0 { return false; }
        true
    }
    #[cfg(not(unix))]
    {
        let _ = metadata;
        true
    }
}

/// The platform's own program: under a platform root, root-owned, not group/other-writable, and every
/// directory above it the same (a writable directory lets anyone replace the file inside it).
///
/// This round's fifth finding: /usr/local/bin and /opt/homebrew belong to the USER on macOS, so a
/// homebrew interpreter was called the platform's and received the vault values unhashed.
fn platform_owned(path: &str) -> bool {
    if !platform_root(path) { return false; }
    let real = real_path(path);
    if !owned_by_root(&real) { return false; }
    let mut dir = parent_of(&real);
    let mut guard = 0;
    while !dir.is_empty() && dir != "/" && guard < 64 {
        if !owned_by_root(&dir) { return false; }
        dir = parent_of(&dir);
        guard += 1;
    }
    true
}

/// A path with symlinks resolved and separators normalized: the form two sides of a comparison must
/// agree on, because /tmp is a symlink on some machines and the digest names what is really there.
fn real_path(path: &str) -> String {
    std::fs::canonicalize(path)
        .map(|value| value.to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|_| path.replace('\\', "/"))
}

/// What a name an argument carries resolves to.
///
/// Round 7: the list of implied extensions was .mjs, .js, .cjs, /index.* - not node's own order, and not
/// even the extensions node implies. Measured on node 26: `node ./a` with only a.mjs beside it fails with
/// "Cannot find module", and with a.mjs AND a.js it runs a.js. So the old list could name a file nothing
/// runs, and a file that does run stayed unhashed - the value went to the file the digest never saw.
#[derive(Debug)]
enum Resolved {
    One(String),
    /// More than one file answers to the same name: which one runs is node's priority, not the approval's,
    /// so the launch is refused rather than resolved (approving `server` with only server.js there, and
    /// adding server.mjs afterwards, must not hand the value to the file nobody hashed).
    Ambiguous(Vec<String>),
    /// Nothing is there, or a relative name has no directory to resolve it from (the launch's own cwd is
    /// not the approval's to assume).
    None,
}

/// The extensions node implies for a name with none, in node's own order (lib/internal/modules/cjs/loader:
/// the exact name, then these), and the files a directory it names is read from.
const NODE_FILE_EXT: [&str; 3] = [".js", ".json", ".node"];
const NODE_INDEX_EXT: [&str; 3] = ["/index.js", "/index.json", "/index.node"];

fn push_file(found: &mut Vec<String>, path: &str) {
    if std::path::Path::new(path).is_file() { found.push(path.to_string()); }
}

/// The package.json main of a directory, resolved the way the name that named the directory is resolved.
fn package_main(dir: &str, depth: u32, found: &mut Vec<String>) {
    if depth > 2 { return; }
    let Ok(text) = std::fs::read_to_string(format!("{dir}/package.json")) else { return };
    let Ok(document) = serde_json::from_str::<Value>(&text) else { return };
    let Some(main) = document["main"].as_str().filter(|value| !value.is_empty()) else { return };
    let target = if is_absolute_path(main) {
        main.replace('\\', "/")
    } else {
        format!("{}/{}", dir.trim_end_matches('/'), main)
    };
    push_file(found, &target);
    for extension in NODE_FILE_EXT { push_file(found, &format!("{target}{extension}")); }
    if std::path::Path::new(&target).is_dir() {
        for extension in NODE_INDEX_EXT { push_file(found, &format!("{target}{extension}")); }
        package_main(&target, depth + 1, found);
    }
}

/// Every file node would consider for this name, in node's own order.
fn node_candidates(target: &str) -> Vec<String> {
    let mut found = Vec::new();
    push_file(&mut found, target);
    if std::path::Path::new(target).extension().is_none() {
        for extension in NODE_FILE_EXT { push_file(&mut found, &format!("{target}{extension}")); }
    }
    if std::path::Path::new(target).is_dir() {
        package_main(target, 0, &mut found);
        for extension in NODE_INDEX_EXT { push_file(&mut found, &format!("{target}{extension}")); }
    }
    found
}

fn resolve_argument(cwd: &str, value: &str) -> Resolved {
    let target = if is_absolute_path(value) {
        value.replace('\\', "/")
    } else if cwd.is_empty() {
        return Resolved::None;
    } else {
        format!("{}/{}", cwd.trim_end_matches('/'), value)
    };
    let mut found = node_candidates(&target);
    if found.len() == 1 { return Resolved::One(found.remove(0)); }
    if found.len() > 1 { return Resolved::Ambiguous(found); }
    Resolved::None
}

/// One file answers to the name, or the launch is refused: two files that both answer to it are a launch
/// whose program is chosen by node's priority rather than by the digest the operator gave.
fn ambiguous_refusal(value: &str, found: &[String]) -> String {
    format!("vault_approval_argument_ambiguous:{value}: more than one file answers to this name ({}), so which one this launch runs is node's own choice rather than the approval's, and nothing was launched and no value was read. Name the file it must run by its absolute path: /mcp <id> probe, then /mcp <id> on", found.join(", "))
}

// ---- the allow-list: what a vault connector may RUN, judged by what the file IS (round 8) --------
//
// Rounds 6-7 refused interpreters by NAME and each review found another name, another wrapper or another
// copy under a different name. A name is not a program: python3, python3.11, pypy, a copy of python called
// `py`, `env node conn.mjs` and `timeout 30 node conn.mjs` all run code this digest cannot follow, and none
// of them is refused by a list that names only the first. So the rule is inverted: the program's REALPATH
// (symlinks resolved) must be one of the two families this digest CAN follow, and the file must be a NATIVE
// executable (ELF, Mach-O or PE) rather than a script wearing that name. Everything else is refused.
// The one exception is a native binary the OPERATOR vouched for at approval time (`/mcp <id> on --native`,
// recorded with its sha256 in the approval): the digest cannot see what a native binary loads.

/// The programs a vault connector may run: node, and the POSIX shells the digest follows. Judged by the
/// program's realpath, never by the path the definition happened to spell.
const ALLOWED_PROGRAMS: [&str; 5] = ["node", "nodejs", "sh", "bash", "dash"];

/// Interpreters whose module system this digest cannot follow: each loads a module or a package from a
/// search path (a python package, a ruby gem, a perl module, a lua rock) that is not a file an approval
/// names. NOT the rule any more (the allow-list is), but an ARGUMENT that resolves to one of these is
/// refused too: `node ./bin/python3 script.py` runs python from a file the digest would otherwise name.
/// The same list is in lua/core/mcp.lua, compared case-insensitively on both sides and pinned by ONE
/// shared table in scripts/test-mcp-vault-approval.lua.
pub(crate) const REFUSED_INTERPRETERS: [&str; 33] = ["python", "python2", "python3", "pypy", "pypy3",
    "perl", "ruby", "php", "lua", "luajit", "tclsh", "expect", "deno", "bun", "qjs", "quickjs",
    "ts-node", "tsx", "java", "jjs", "pwsh", "powershell", "julia", "elixir", "escript", "erl",
    "rscript", "groovy", "scala", "kotlin", "swift", "dotnet", "mono"];

/// Wrappers: each one RUNS the program that follows it, so the file an approval names is not the file that
/// runs. `sh -c 'env ...'` is already refused as inline code; this is `program=/usr/bin/env`, and an
/// argument that resolves to one of them.
pub(crate) const REFUSED_WRAPPERS: [&str; 17] = ["env", "nice", "ionice", "timeout", "setsid", "stdbuf",
    "xargs", "sudo", "doas", "nohup", "chrt", "taskset", "unshare", "firejail", "bwrap", "flock", "time"];

/// A versioned name is the same interpreter (python3.11, perl5.36, ruby3.2, php8.2).
fn stem_of(name: &str) -> &str {
    name.trim_end_matches(|character: char| character.is_ascii_digit() || character == '.')
}

/// Interpreter or wrapper, from a name: the kind, and the name that matched. Compared case-insensitively,
/// because a Rust list matched `Rscript` only by accident while the Lua list lowercased (round 8's
/// finding 5: one shared table, one case rule).
pub(crate) fn refused_interpreter_or_wrapper(name: &str) -> Option<(&'static str, &'static str)> {
    let clean = name.trim_end_matches(".exe").to_ascii_lowercase();
    let stem = stem_of(&clean).to_string();
    if let Some(known) = REFUSED_WRAPPERS.iter().find(|known| **known == clean || **known == stem) {
        return Some(("wrapper", known));
    }
    if let Some(known) = REFUSED_INTERPRETERS.iter().find(|known| **known == clean || **known == stem) {
        return Some(("interpreter", known));
    }
    None
}

/// A file's kind from its leading bytes, or None when the host cannot say. A name is never the answer: a
/// copy of python called `node`, or a `#!/bin/sh` wrapper called `bash`, is exactly what a list of names
/// cannot refuse.
fn file_magic(path: &str) -> Option<String> {
    let value = crate::host::file_magic_value(path);
    value["magic"].as_str().map(str::to_string)
}

fn native_executable(path: &str) -> bool {
    matches!(file_magic(path).as_deref(), Some("elf") | Some("macho") | Some("pe"))
}

/// The operator's own voucher for a native binary (`/mcp <id> on --native`): {path, sha256}, recorded in
/// the approval. Its bytes are in the digest like any other approved file, so replacing the binary voids
/// the approval.
fn native_voucher(approval: &Value) -> Option<(String, String)> {
    let native = approval.get("native")?;
    let path = native["path"].as_str().unwrap_or_default();
    if path.is_empty() { return None; }
    Some((real_path(path), native["sha256"].as_str().unwrap_or_default().to_lowercase()))
}

/// The one judgement about a PROGRAM, made in the console and again here from the bytes on disk.
/// `vouched` is the realpath the approval's `--native` record names, or None.
pub(crate) fn program_refusal(program: &str, vouched: Option<&str>) -> Option<String> {
    let name = basename(program).trim_end_matches(".exe").to_string();
    if PACKAGE_RUNNERS.contains(&name.as_str()) {
        return Some(format!("vault_approval_package_runner:{program}: this connector's program is a package runner ({name}), whose code comes from a cache or a registry rather than from files an approval can name, so nothing was launched and no value was read. Give it its own absolute program at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
    }
    if !is_absolute_path(program) {
        return Some(format!("vault_approval_program_not_absolute:{program}: this connector's program is a bare name, which is resolved through PATH rather than named by the digest, so nothing was launched and no value was read. Name the absolute path of its interpreter or binary: /mcp <id> probe, then /mcp <id> on"));
    }
    // The name of what the path RESOLVES to, so a symlink or another name cannot choose another answer.
    // real_path falls back to the path itself when the file is not there, which is why an interpreter is
    // named as one before existence is asked: `/usr/bin/python3` is an interpreter whether or not this
    // host installed it at that path, and that is the sentence the operator has to act on.
    let real = real_path(program);
    let real_name = basename(&real).trim_end_matches(".exe").to_string();
    // The two families are refused BEFORE the voucher is looked at: --native vouches for a NATIVE BINARY
    // the allow-list has no opinion about, not for python3 or env. A wrapper is refused even when vouched
    // for (a voucher checked first turned /usr/bin/env into an approved program).
    if let Some((kind, matched)) = refused_interpreter_or_wrapper(&real_name) {
        if kind == "wrapper" {
            return Some(format!("vault_approval_program_wrapper:{program}: this connector's program resolves to {real}, which is a wrapper ({matched}) that runs another program, so the file the approval names is not the file that runs, and nothing was launched and no value was read. Run the connector under node or a POSIX shell: /mcp <id> probe, then /mcp <id> on"));
        }
        if kind == "interpreter" {
            return Some(format!("vault_approval_program_not_allowed:{program}: this connector's program resolves to {real}, which is an interpreter ({matched}) whose modules and packages this digest cannot follow, so nothing was launched and no value was read. A vault connector runs node or a POSIX shell, judged by the program's realpath, or a native binary the operator vouches for with /mcp <id> on --native: /mcp <id> probe, then /mcp <id> on"));
        }
    }
    if vouched == Some(real.as_str()) {
        // The voucher is about a FILE, and about a NATIVE EXECUTABLE: a script under the voucher is the
        // same interpreter in disguise the allow-list exists to refuse.
        if native_executable(&real) { return None; }
        return Some(format!("vault_approval_program_native_not_executable:{program}: this connector's program resolves to {real}, which the operator vouched for with --native but which is not a native executable: --native approves a native binary, never a script, so nothing was launched and no value was read. Name the real interpreter: /mcp <id> probe, then /mcp <id> on"));
    }
    // A path that is not a file is not a coverage problem: saying `not_covered` for a program that is
    // simply absent sent the operator to approve a file that does not exist (the Lua side says "cannot
    // be read" for the same fact).
    if !std::path::Path::new(program).exists() {
        return Some(format!("vault_approval_program_missing:{program}: this connector's program is not a file on this node, so nothing was launched and no value was read. Name the absolute path of its interpreter or binary: /mcp <id> probe, then /mcp <id> on"));
    }
    if ALLOWED_PROGRAMS.contains(&real_name.as_str()) {
        if native_executable(&real) { return None; }
        return Some(format!("vault_approval_program_not_native:{program}: this connector's program resolves to {real}, which is named {real_name} but is not a native executable: a script or a plain file under an allowed name is an interpreter in disguise, so nothing was launched and no value was read. Name the real interpreter, or record a native binary at the operator's terminal with /mcp <id> on --native: /mcp <id> probe, then /mcp <id> on"));
    }
    Some(format!("vault_approval_program_not_allowed:{program}: this connector's program resolves to {real}, which is not node or a POSIX shell (sh, bash, dash), so nothing was launched and no value was read. A vault connector runs node or a POSIX shell, judged by the program's realpath, or a native binary the operator vouches for with /mcp <id> on --native: /mcp <id> probe, then /mcp <id> on"))
}

/// An ARGUMENT that resolves to an interpreter or a wrapper is refused the same way: the digest can name
/// the file, but not what running it runs.
fn argument_refusal(value: &str, target: &str) -> Option<String> {
    let real = real_path(target);
    let name = basename(&real).trim_end_matches(".exe").to_string();
    let (kind, _) = refused_interpreter_or_wrapper(&name)?;
    Some(format!("vault_approval_argument_not_allowed:{value}: this connector's argument resolves to {real}, which is a {kind} whose code this digest cannot name, so nothing was launched and no value was read. Name a script file instead: /mcp <id> probe, then /mcp <id> on"))
}

/// An option that names a FILE rather than a value.
fn path_option(name: &str) -> bool {
    matches!(name, "--require" | "-r" | "--import" | "--loader" | "--experimental-loader"
        | "--env-file" | "--config")
}

/// A flag that makes an interpreter run a STRING, matched before an '=' and through a short cluster.
fn code_flag(flags: &[&str], value: &str) -> Option<String> {
    // Round 8: the flag is compared BEFORE an '=', and a short cluster is split (-pe is -p and -e), so
    // one argument cannot smuggle two flags past a list that compares whole strings. A long option is
    // never split: --print is one flag, not --p, --r, --i, --n, --t.
    let head = value.split('=').next().unwrap_or(value);
    if flags.contains(&head) { return Some(head.to_string()); }
    let bytes = head.as_bytes();
    if bytes.len() > 2 && bytes[0] == b'-' && bytes[1] != b'-' {
        for index in 1..bytes.len() {
            let short = format!("-{}", bytes[index] as char);
            if flags.contains(&short.as_str()) { return Some(format!("{short} (in {head})")); }
        }
    }
    None
}

const JS_INLINE_FLAGS: [&str; 4] = ["-e", "--eval", "-p", "--print"];
const SH_INLINE_FLAGS: [&str; 2] = ["-c", "--command"];
const CODE_FLAGS: [&str; 13] = ["-c", "-e", "-E", "-m", "-p", "-r", "--eval", "--print", "--command",
    "-command", "-encodedcommand", "--module", "--require"];

/// The family a program belongs to, for the flags that mean \"run this string\": decided from the REALPATH,
/// so a symlink or another name cannot choose another family's rules.
fn interpreter_family(program: &str) -> &'static str {
    let name = basename(&real_path(program)).trim_end_matches(".exe").to_string();
    match name.as_str() {
        "node" | "nodejs" => "js",
        "sh" | "bash" | "dash" | "zsh" | "ksh" => "sh",
        other if refused_interpreter_or_wrapper(other).is_some() => "other",
        _ => "unknown",
    }
}

/// A flag that makes the interpreter run a STRING: the one shape no digest of files can name.
fn inline_flag(program: &str, value: &str) -> Option<String> {
    match interpreter_family(program) {
        "js" => code_flag(&JS_INLINE_FLAGS, value),
        "sh" => code_flag(&SH_INLINE_FLAGS, value),
        _ => code_flag(&CODE_FLAGS, value),
    }
}

/// This round's second and third findings, from the approval's own data: every argument is resolved the
/// way node resolves it, and each one that names a file must be a file the approval covers. An argument
/// that may name a file and cannot be resolved is refused, because a file that is not there when the
/// operator approved the connector can be there when it launches. An inline string is refused outright.
fn argument_problem(cwd: &str, program: &str, args: &[String], covered: &[String]) -> Result<(), String> {
    let mut pending = String::new();
    for value in args {
        let option = value.starts_with('-') && value.len() > 1;
        if option {
            if let Some(flag) = inline_flag(program, value) {
                return Err(format!("vault_approval_inline_code:{flag}: this connector runs inline code ({value}), which no digest of files can name, so nothing was launched and no value was read. Give it a script file: /mcp <id> probe, then /mcp <id> on"));
            }
        }
        if option {
            let (name, inline) = match value.split_once('=') {
                Some((name, inline)) if name.starts_with("--") => (name.to_string(), Some(inline.to_string())),
                _ => (value.clone(), None),
            };
            if let Some(inline) = inline {
                if path_option(&name) {
                    let target = match resolve_argument(cwd, &inline) {
                        Resolved::One(target) => target,
                        Resolved::Ambiguous(found) => return Err(ambiguous_refusal(&inline, &found)),
                        Resolved::None => return Err(format!("vault_approval_file_not_found:{inline}: this connector names a file ({inline}, after {name}) that is not there, so nothing was launched and no value was read. Give its absolute path: /mcp <id> probe, then /mcp <id> on")),
                    };
                    if !covered.iter().any(|path| real_path(path) == real_path(&target)) {
                        return Err(format!("vault_approval_argument_not_covered:{target}: this connector runs a file the approval does not name, so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
                    }
                }
            }
            pending = name;
            continue;
        }
        match resolve_argument(cwd, value) {
            Resolved::One(target) => {
                if let Some(problem) = argument_refusal(value, &target) { return Err(problem); }
                if !covered.iter().any(|path| real_path(path) == real_path(&target)) {
                    return Err(format!("vault_approval_argument_not_covered:{target}: this connector runs a file the approval does not name, so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
                }
            }
            Resolved::Ambiguous(found) => return Err(ambiguous_refusal(value, &found)),
            Resolved::None if !pending.is_empty() && !path_option(&pending) => {}
            Resolved::None if !pending.is_empty() => {
                return Err(format!("vault_approval_file_not_found:{value}: this connector names a file ({value}, after {pending}) that is not there, so nothing was launched and no value was read. Give its absolute path: /mcp <id> probe, then /mcp <id> on"));
            }
            Resolved::None if looks_like_path(value) => {
                return Err(format!("vault_approval_path_not_absolute:{value}: this connector runs a path relative to its own directory, which the digest cannot name, so nothing was launched and no value was read. Name its absolute path: /mcp <id> probe, then /mcp <id> on"));
            }
            Resolved::None => {
                return Err(format!("vault_approval_argument_unresolved:{value}: this connector's argument may name a file this digest cannot resolve from its own directory, so nothing was launched and no value was read. Give its absolute path: /mcp <id> probe, then /mcp <id> on"));
            }
        }
        pending.clear();
    }
    Ok(())
}

/// A path-shaped argument is one the launch could read: it has a separator, or it carries a script
/// extension. A URL is data, never a local path.
fn looks_like_path(value: &str) -> bool {
    if value.is_empty() || value.contains("://") { return false; }
    if value.contains('/') || value.contains('\\') { return true; }
    std::path::Path::new(value).extension().and_then(|ext| ext.to_str())
        .is_some_and(|ext| SCRIPT_EXTENSIONS.iter().any(|known| ext.eq_ignore_ascii_case(known)))
}

/// Why a program cannot be covered, or None when it can: the ALLOW-LIST of round 8, judged by the
/// program's realpath and by what the file IS, with no voucher (the console's own question, before an
/// operator has recorded one).
fn program_shape_problem(program: &str) -> Option<String> {
    program_refusal(program, None)
}

/// Nothing is launched and no value is read unless the launch matches the approval the operator gave.
/// Each refusal names what is wrong and what to do, because the reader of a refusal is the one who can
/// approve the connector again.
/// The bytes the approval was checked against, path and sha256, so the same bytes can be checked AGAIN
/// after the spawn (recheck_after_spawn): the window between this hash and the child's open is the one
/// this round's fourth finding names.
type VerifiedFiles = Vec<(String, String)>;

fn approval_problem(approval: &Value, launch: &Spec) -> Result<VerifiedFiles, String> {
    let expected = approval["sha256"].as_str().unwrap_or_default().trim().to_string();
    if expected.is_empty() {
        return Err("vault_approval_required: this connector names a vault entry but carries no approval digest, so no value was read and nothing was launched. A vault connector is approved at the operator's own terminal: /mcp <id> probe, then /mcp <id> on".into());
    }
    if approval["form"].as_str().unwrap_or_default() != APPROVAL_FORM {
        return Err("vault_approval_digest_form: this connector's approval predates the fields that say what it covers (its directory, its plain environment and every file it can load), so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on".into());
    }
    let program = approval["program"].as_str().unwrap_or_default().to_string();
    let cwd = approval["cwd"].as_str().unwrap_or_default().to_string();
    let args: Vec<String> = approval["args"].as_array()
        .map(|list| list.iter().filter_map(|value| value.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    let mut env: Vec<(String, String)> = approval["env"].as_array()
        .map(|list| list.iter().map(|entry| (
            entry["name"].as_str().unwrap_or_default().to_string(),
            entry["ref"].as_str().unwrap_or_default().to_string())).collect())
        .unwrap_or_default();
    env.sort();
    let mut vault: Vec<String> = approval["vault"].as_array()
        .map(|list| list.iter().filter_map(|value| value.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    vault.sort();
    // Round 9: the voucher is read BEFORE the files, because the console puts the vouched binary in that
    // list (lua/core/mcp.lua, M.vault_manifest). Reading it after the loop answered `vault_approval_
    // unreadable` - "a script this connector was approved with" - for a native binary that is gone, and
    // left `vault_approval_native_unreadable` reachable only by an approval the console never writes.
    let voucher = native_voucher(approval);
    let vouched_path = voucher.as_ref().map(|(path, _)| real_path(path));
    let mut files: Vec<(String, String)> = Vec::new();
    for entry in approval["files"].as_array().map(Vec::as_slice).unwrap_or_default() {
        let path = entry.as_str().unwrap_or_default();
        if path.is_empty() {
            return Err("vault_approval_required: this connector carries an approval with no script list, so no value was read. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on".into());
        }
        // Round 9: the vouched BINARY is hashed by STREAM (crate::host::file_digest), never read whole.
        // A native interpreter is up to half a gigabyte, and reading it into memory to hash it is an
        // allocation an approval check must not make; the scripts are small and stay as they were.
        let vouched_here = vouched_path.as_deref() == Some(real_path(path).as_str());
        let digest = if vouched_here {
            match crate::host::file_digest(path) {
                Ok(digest) => Some(digest),
                Err(reason) => {
                    return Err(format!("vault_approval_native_unreadable:{path}: the native binary this connector was approved on cannot be read now ({reason}), so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> on --native"));
                }
            }
        } else {
            std::fs::read(path).ok().map(|bytes| sha256_hex(&bytes))
        };
        let Some(digest) = digest else {
            return Err(format!("vault_approval_unreadable:{path}: a script this connector was approved with cannot be read now, so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
        };
        files.push((path.to_string(), digest));
    }
    files.sort_by(|left, right| left.0.cmp(&right.0));
    // The digest is only worth something if it covers what is being STARTED: every script on this
    // launch's own command line must be one of the files it names.
    for arg in launch.args.iter() {
        if !is_script_path(arg) { continue; }
        if !files.iter().any(|(path, _)| path == arg) {
            return Err(format!("vault_approval_script_not_covered:{arg}: this launch runs a script the approval does not cover, so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
        }
    }
    // ... and the same for the connector's own command: a relative path is resolved from its cwd, and a
    // program outside the platform's roots is its own code. Round 8: the operator's own voucher for a
    // native binary is read here, and it has to name the bytes that are there NOW - replacing the binary
    // is a `vault_approval_mismatch`, not a launch.
    if let Some((path, sha)) = voucher.as_ref() {
        // Streaming, for the same reason as the file list: this is a native binary, not a script.
        let Ok(digest) = crate::host::file_digest(path) else {
            return Err(format!("vault_approval_native_unreadable:{path}: the native binary this connector was approved on cannot be read now, so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> on --native"));
        };
        if !digest.eq_ignore_ascii_case(sha) {
            return Err(format!("vault_approval_native_changed:{path}: the native binary this connector was approved on is not the bytes the operator vouched for, so nothing was launched and no value was read. A native binary's own loads are outside this digest; approve it again with /mcp <id> on --native"));
        }
        if !files.iter().any(|(known, _)| real_path(known) == real_path(path)) {
            return Err(format!("vault_approval_native_not_covered:{path}: the native binary this connector was approved on is not in the files the approval names, so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> on --native"));
        }
    }
    let vouched = voucher.as_ref().map(|(path, _)| path.as_str());
    if let Some(problem) = program_refusal(&program, vouched) { return Err(problem); }
    // Every argument, resolved the way node resolves it: the file a bare word names is a file this
    // launch runs, and an inline string is a file no digest can name (argument_problem).
    let covered: Vec<String> = files.iter().map(|(path, _)| path.clone()).collect();
    argument_problem(&cwd, &program, &args, &covered)?;
    let program_vouched = vouched == Some(real_path(&program).as_str());
    if !platform_owned(&program) && !program_vouched && !files.iter().any(|(path, _)| path == &program) {
        return Err(format!("vault_approval_program_not_covered:{program}: this connector's own program is not a file the approval names, so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
    }
    // The interpreter the launch SPAWNS is the process the values are put in, and it is not always the
    // definition's program (node_program in lua/core/mcp.lua): it must be the platform's own or a file
    // this approval names. WA_NODE may name anything, and <data>/node belongs to the agent's user.
    let spawned = real_path(&launch.program);
    // The spawned interpreter is subject to the same allow-list as the connector's own program: WA_NODE
    // may name a python, a wrapper, or a copy of node that is only a shell script.
    if let Some(problem) = program_refusal(&spawned, None) { return Err(problem); }
    if !platform_owned(&spawned) && !files.iter().any(|(path, _)| real_path(path) == spawned) {
        return Err(format!("vault_approval_interpreter_not_covered:{spawned}: the interpreter this launch puts the value in is neither the platform's own nor a file the approval names, so nothing was launched and no value was read. Name it at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
    }
    let native_line = voucher.as_ref().map(|(path, sha)| (real_path(path), sha.clone()));
    let digest = sha256_hex(approval_text(&program, &cwd, &env, &args, &files, &vault,
        native_line.as_ref().map(|(path, sha)| (path.as_str(), sha.as_str()))).as_bytes());
    if !digest.eq_ignore_ascii_case(&expected) {
        return Err(format!("vault_approval_mismatch: this connector's program, arguments or scripts changed after the operator approved it, so nothing was launched and no value was read (approved {expected}, now {digest}). Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
    }
    Ok(files)
}

/// The same files, hashed AGAIN after the spawn: a rewrite in the window between the check and the
/// child's first open is not caught by either hash alone, so the operation is killed and its result is
/// never read. It does not make the window zero (the child may already have run); docs/VAULT.md says
/// exactly that, and what remains is a rewrite that must land inside a few milliseconds.
fn recheck_after_spawn(files: &VerifiedFiles) -> Option<String> {
    for (path, expected) in files.iter() {
        match crate::host::file_digest(path) {
            Ok(now) if now.eq_ignore_ascii_case(expected) => {}
            _ => return Some(format!("vault_approval_changed_since_check:{path}: a file this connector runs changed between the check and the launch, so the operation was killed - the value had already been put in its environment at launch, so treat it as exposed and rotate it if this change was not yours. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on")),
        }
    }
    None
}

// ---- the request file the child reads, and why the kernel has to seal it ------------------------
//
// (This round's first hole.) lua/core/mcp.lua writes the whole launch to <data>/mcp/requests/<uuid>.json
// and the client spawns server.program / args / cwd FROM THAT FILE, with the vault values in its
// environment - but the approval above describes the connector's command, and nothing compared the two.
// The file is also writable by the agent (until this round it was not even in secret_guard), so a
// background loop could rewrite server.program between the console's write and the child's read and
// choose the program that got the value.
//
// Two halves close it:
//   * the kernel reads the file, checks its server against the approval the operator gave, and hands the
//     child the sha256 of the EXACT bytes it checked (WA_MCP_REQUEST_FILE / WA_MCP_REQUEST_SHA256);
//   * the child (scripts/mcp-client.mjs, scripts/mcp-session.mjs) hashes the bytes it read, once, and
//     refuses mcp_request_changed_since_approval unless they are those bytes - so a rewrite after this
//     check cannot reach a spawn.
const REQUEST_FLAGS: [&str; 2] = ["--request-file", "--seed-file"];
const REQUEST_MAX_BYTES: usize = 2 * 1024 * 1024;

fn request_flag(args: &[String]) -> Option<String> {
    for (index, arg) in args.iter().enumerate() {
        if REQUEST_FLAGS.contains(&arg.as_str()) {
            if let Some(path) = args.get(index + 1) { if !path.is_empty() { return Some(path.clone()); } }
        }
    }
    None
}

fn string_list(value: Option<&Value>) -> Vec<String> {
    value.and_then(|list| list.as_array())
        .map(|list| list.iter().filter_map(|item| item.as_str().map(str::to_string)).collect())
        .unwrap_or_default()
}

/// The server a request names must be the command the operator approved, and every path in it must be
/// one the approval covers. This is the check the approval was missing: it describes the connector's
/// command, and the child spawns whatever the file says.
fn request_server_problem(bytes: &[u8], approval: &Value) -> Result<(), String> {
    let unreadable = || "vault_request_unreadable: the request this launch reads is not a JSON object a launch can be checked against, so nothing was launched and no value was read. Approve the connector again at the operator's terminal: /mcp <id> probe, then /mcp <id> on".to_string();
    let text = std::str::from_utf8(bytes).map_err(|_| unreadable())?;
    let request: Value = serde_json::from_str(text).map_err(|_| unreadable())?;
    let server = request.get("server").filter(|value| value.is_object()).ok_or_else(unreadable)?;
    if server["transport"].as_str() != Some("stdio") {
        return Err("vault_request_transport_not_checked: this request does not name a stdio connector, whose command the approval covers, so nothing was launched and no value was read. Approve the connector again at the operator's terminal: /mcp <id> probe, then /mcp <id> on".into());
    }
    let program = server["program"].as_str().unwrap_or_default();
    let approved_program = approval["program"].as_str().unwrap_or_default();
    if program != approved_program {
        return Err(format!("vault_request_program_mismatch: the request this launch reads names a program ({program}) the operator did not approve ({approved_program}), so nothing was launched and no value was read. Approve the connector again at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
    }
    let args = string_list(server.get("args"));
    if args != string_list(approval.get("args")) {
        return Err("vault_request_arguments_mismatch: the request this launch reads runs a command line the operator did not approve, so nothing was launched and no value was read. Approve the connector again at the operator's terminal: /mcp <id> probe, then /mcp <id> on".into());
    }
    let cwd = server.get("cwd").and_then(|value| value.as_str()).unwrap_or_default();
    if cwd != approval["cwd"].as_str().unwrap_or_default() {
        return Err("vault_request_cwd_mismatch: the request this launch reads runs in a directory the operator did not approve, so nothing was launched and no value was read. Approve the connector again at the operator's terminal: /mcp <id> probe, then /mcp <id> on".into());
    }
    // The environment the child hands the server is the operator's too: the definition's own references
    // plus one self-reference per vault entry the kernel injects. Another name here is another variable
    // the connector reads - or one it drops.
    let mut expected: Vec<(String, String)> = approval["env"].as_array()
        .map(|list| list.iter().map(|entry| (
            entry["name"].as_str().unwrap_or_default().to_string(),
            entry["ref"].as_str().unwrap_or_default().to_string())).collect())
        .unwrap_or_default();
    for name in string_list(approval.get("vault")) { expected.push((name.clone(), name)); }
    expected.sort();
    let mut observed: Vec<(String, String)> = server.get("env").and_then(|value| value.as_object())
        .map(|map| map.iter().map(|(name, reference)| (
            name.clone(), reference.as_str().unwrap_or_default().to_string())).collect())
        .unwrap_or_default();
    observed.sort();
    if observed != expected {
        return Err("vault_request_environment_mismatch: the request this launch reads hands the connector an environment the operator did not approve, so nothing was launched and no value was read. Approve the connector again at the operator's terminal: /mcp <id> probe, then /mcp <id> on".into());
    }
    // Round 9: the operator's voucher is part of the SAME judgement here as in approval_problem. Without
    // it a vouched native binary passed the approval and was refused by this check, so `/mcp <id> on
    // --native` could not work end to end (the review's first item).
    let voucher = native_voucher(approval);
    let vouched = voucher.as_ref().map(|(path, _)| path.as_str());
    if let Some(problem) = program_refusal(program, vouched) { return Err(problem); }
    let files = string_list(approval.get("files"));
    // The same resolution the console applies when it records the approval, in this request's own words:
    // the file a bare argument names is a file this request runs (a bare word is a file beside the
    // connector when one is there), and an inline string is refused.
    if let Err(problem) = argument_problem(cwd, program, &args, &files) {
        return Err(problem.replacen("vault_approval_", "vault_request_", 1)
            .replace("this connector", "this request"));
    }
    let program_vouched = vouched == Some(real_path(program).as_str());
    if !platform_owned(program) && !program_vouched && !files.iter().any(|path| path == program) {
        return Err(format!("vault_request_program_not_covered:{program}: this request's program is not a file the approval names, so nothing was launched and no value was read. Approve the connector again at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
    }
    Ok(())
}

/// Seal the request file a launch reads: check its server against the approval (a vault launch only) and
/// hand the child the sha256 of these exact bytes. A vault launch that names no request file is refused -
/// the approval covers a command, and there is nothing to compare that command against.
fn seal_request(launch: &mut Spec, approval: &Value, vault_launch: bool) -> Result<(), String> {
    let Some(path) = request_flag(&launch.args) else {
        return if vault_launch {
            Err("vault_request_unnamed: this vault connector's launch names no request file, so there is nothing to check the approved command against and nothing was launched. Approve the connector again at the operator's terminal: /mcp <id> probe, then /mcp <id> on".into())
        } else { Ok(()) };
    };
    let bytes = std::fs::read(&path)
        .map_err(|_| format!("mcp_request_unreadable:{path}: the request this launch reads is gone, so nothing was launched"))?;
    if bytes.len() > REQUEST_MAX_BYTES {
        return Err(format!("mcp_request_too_large:{path}: the request is larger than a launch reads ({} bytes), so nothing was launched", bytes.len()));
    }
    if vault_launch { request_server_problem(&bytes, approval)?; }
    // The same value twice is one variable: a request that names one of these itself cannot override it.
    launch.env.retain(|(name, _)| name != "WA_MCP_REQUEST_FILE" && name != "WA_MCP_REQUEST_SHA256");
    launch.env.push(("WA_MCP_REQUEST_FILE".into(), path));
    launch.env.push(("WA_MCP_REQUEST_SHA256".into(), sha256_hex(&bytes)));
    Ok(())
}


fn command_result(manager: &Manager, id: &str, mut state: Value) -> Value {
    let code = state["process_exit_code"].as_i64().unwrap_or(-1);
    if let Ok(page) = manager.read(id, "stdout", 0, 24 * 1024) {
        state["stdout"] = page["content"].clone();
        state["stdout_truncated"] =
            json!(page["available_bytes"].as_u64().unwrap_or(0) > 24 * 1024);
    }
    if let Ok(page) = manager.read(id, "stderr", 0, 8 * 1024) {
        state["stderr"] = page["content"].clone();
        let available = page["available_bytes"].as_u64().unwrap_or(0);
        state["stderr_bytes"] = json!(available);
        state["stderr_truncated"] = json!(available > 8 * 1024);
    }
    state["command_completed"] = json!(true);
    state["command_code"] = json!(code);
    state["command_ok"] = json!(code == 0);
    state["completion_scope"] = json!("command");
    state["operation_settled"] = state["settled"].clone();
    state["ok"] = json!(code == 0);
    state["code"] = json!(code);
    state["output_complete"] = json!(state["output_streams_closed"] == true);
    state["note"] = json!(format!(
        "the shell command completed with exit code {code}; descendants remain supervised as operation {id} under the original command timeout. Their work is not complete, and they may produce more output. Observe or await full settlement only if the task depends on them."
    ));
    state
}
/// The names this node's policy re-grants to tool children: "tool_env_allow": ["GH_TOKEN", ...] in the
/// grant policy file (wa_features::policy_path). Read here, once, because this is where the one manager
/// every tool child crosses is built; the deny list itself lives in wa-operation.
fn tool_env_allow() -> Vec<String> {
    let path = wa_features::policy_path();
    let Ok(raw) = std::fs::read_to_string(&path) else { return Vec::new() };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) else { return Vec::new() };
    value["tool_env_allow"].as_array().map(|items| items.iter()
        .filter_map(|item| item.as_str().map(str::to_string)).collect()).unwrap_or_default()
}

pub fn manager() -> &'static Manager {
    static MANAGER: OnceLock<Manager> = OnceLock::new();
    MANAGER.get_or_init(|| {
        // A name the operator lists is handed to tool children again; every other name the deny rule
        // matches stays withheld (session isolation, finding 5 round 2).
        wa_operation::set_env_allow(tool_env_allow());
        let home = std::path::PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into()));
        Manager::new(home.join(".wasm-agent/operations"))
            // A shell whose recorded directory is gone starts in the agent home, and says so in
            // its result, instead of inheriting a directory that no longer exists (a released
            // worktree is the ordinary way this happens). See `Manager::with_fallback_cwd`.
            .with_fallback_cwd(home)
        // A command the agent runs can print the node's own key; the operation's stdout is
        // written as it arrives, so redact before the write, not only in the transcript.
        .with_env_secrets()
    })
}
// The preserved draft used script files. A named refusal is the narrower safe route:
// no script with changed $0 semantics or credential-bearing command artifact is executed.
//
// The inline bound is not a style rule. Git-Bash on Windows silently CUTS a `-c` string at
// 8192 bytes: a 9000-byte command ran, did nothing and exited 0, so the refusal has to stay
// below that. What changes here is that an over-long command is no longer refused - it is
// staged to a private file and executed as `bash <file>`, the exact route the refusal used
// to tell the caller to take by hand. Bytes are preserved verbatim, and the result says
// `staged_script` so the one semantic difference ($0 is the script path, not "bash") is
// visible rather than implied.
const WINDOWS_INLINE_COMMAND_BUDGET: usize = 8192;
// Still bounded: a staged script is a real file, not an unbounded dump.
const STAGED_COMMAND_LIMIT: usize = 1 << 20;

pub(crate) struct Launch {
    pub program: String,
    pub args: Vec<String>,
    pub staged: Option<std::path::PathBuf>,
}

fn command_line_overflow(program: &str, flag: &str, command: &str) -> bool {
    let escaped = |s: &str| s.encode_utf16().map(|c| if c == 34 || c == 92 { 2 } else { 1 }).sum::<usize>();
    cfg!(windows) && escaped(program) + escaped(flag) + escaped(command) + 520 > WINDOWS_INLINE_COMMAND_BUDGET
}

fn commands_dir() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    std::path::PathBuf::from(home).join(".wasm-agent/commands")
}

fn stage_command(command: &str) -> Result<std::path::PathBuf, String> {
    stage_command_in(&commands_dir(), command)
}

fn stage_command_in(dir: &std::path::Path, command: &str) -> Result<std::path::PathBuf, String> {
    use std::io::Write;
    std::fs::create_dir_all(dir).map_err(|e| format!("shell_command_stage_failed: {e}"))?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let path = dir.join(format!("command-{}-{stamp}.sh", std::process::id()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&path).map_err(|e| format!("shell_command_stage_failed: {e}"))?;
    file.write_all(command.as_bytes())
        .map_err(|e| format!("shell_command_stage_failed: {e}"))?;
    Ok(path)
}

// Inline when it fits; otherwise the same bytes run from a staged script file.
fn command_launch(program: &str, flag: &str, command: &str) -> Result<Launch, String> {
    if command.len() > STAGED_COMMAND_LIMIT {
        return Err(format!(
            "shell_command_too_long: {} bytes; a staged script is capped at {STAGED_COMMAND_LIMIT} bytes - write the script yourself and run it by path",
            command.len()
        ));
    }
    if !command_line_overflow(program, flag, command) {
        return Ok(Launch { program: program.into(), args: vec![flag.into(), command.into()], staged: None });
    }
    let path = stage_command(command)?;
    Ok(Launch { program: program.into(), args: vec![path.to_string_lossy().into_owned()], staged: Some(path) })
}
fn spec(launch: &Launch, cwd: &str, seconds: u64, owner: String, promote: bool, background: bool) -> Spec {
    configure_spec(
        Spec::command(launch.program.clone(), launch.args.clone()),
        cwd,
        seconds,
        owner,
        promote,
        background,
    )
}
/// The kinds an operation can be, and what each one's default deadline is when the caller gives none.
///
/// Measured on wasm_the_first (2026-11-10): a supervised build was killed at the 300 s default because the
/// caller passed no `timeout_seconds` at all - the deadline existed, was applied, and was never said. `bash`
/// documents its own 300 s in the tool description, but `operation start` promised a supervised long command
/// and silently gave it the short one. The default now follows what the command IS, and every start that used
/// a default says so in its receipt (`timeout_source`, `timeout_kind`, `timeout_notice`), so nobody has to
/// learn it from a kill.
pub(crate) const OPERATION_KINDS: [&str; 4] = ["command", "build", "test", "deploy"];

pub(crate) fn default_operation_timeout_seconds(kind: &str) -> u64 {
    match kind {
        "build" => 5400,
        "test" => 3600,
        "deploy" => 3600,
        _ => 300,
    }
}

/// What this operation is: the caller's explicit `kind`, or a conservative read of its command line.
/// An explicit kind is validated; an inference is only ever used to pick a default, and the receipt says
/// which one was used, so a wrong guess costs time and never silently shortens the caller's intent.
pub(crate) fn operation_kind(args: &Value, command: &str) -> Result<&'static str, String> {
    if let Some(kind) = args["kind"].as_str().filter(|kind| !kind.is_empty()) {
        return OPERATION_KINDS.iter().copied().find(|known| *known == kind)
            .ok_or_else(|| format!("operation_kind_unknown:{kind}: expected one of {}", OPERATION_KINDS.join(", ")));
    }
    let text = command.to_ascii_lowercase();
    if ["cargo build", "build-window.sh", "codemode-build", "publish-node-binaries", "build-components", "build-plugins"]
        .iter().any(|needle| text.contains(needle)) {
        return Ok("build");
    }
    if ["deploy.sh", "upgrade.sh", "install.sh", "wa update", "wa update"].iter().any(|needle| text.contains(needle)) {
        return Ok("deploy");
    }
    if ["test.sh", "fast.sh", "cargo test", "test-", "bench-"].iter().any(|needle| text.contains(needle)) {
        return Ok("test");
    }
    Ok("command")
}

fn configure_spec(mut spec: Spec, cwd: &str, seconds: u64, owner: String, promote: bool, background: bool) -> Spec {
    spec.cwd = cwd.into();
    spec.timeout = Duration::from_secs(seconds);
    // A foreground `bash` adopts a descendant tree it cannot wait for; a deliberately
    // started operation is already background and never needs to.
    spec.promote_descendants = promote;
    // Low CPU priority is for work nobody waits for (18/11 round 2, finding 9): the caller says which
    // this is, because the fact has to be known before the process is created.
    spec.background = background;
    // A child's operation is owned by the child session/run, not by whatever
    // interpreter slot happens to be on this thread, so settlement is attributable.
    spec.owner = crate::subagents::current_owner().unwrap_or(owner);
    if crate::serve::in_turn() || crate::subagents::current_provenance() == Some("child") {
        spec.env.push(("WASM_AGENT_IN_TURN".into(), "1".into()));
    } // naming-check: allow (installed deploy scripts)
    // Who this process is, so a guard can decide by role. The host knows it from the thread's own
    // task context (a run of a session is `orchestrator`, a subagent task is `child`), and the
    // commit guard in `.githooks/pre-commit` reads it: that is what lets the node's orchestrator
    // session land on `main` while a child cannot get there by exporting the old
    // `WASM_AGENT_ALLOW_MAIN` flag, which said nothing about who was committing. Pushed beside the
    // turn boolean so the bash tool and `operation start` cannot disagree about the answer.
    //
    // Pushed for *every* shell, including an explicit empty value when this thread has no task
    // context, because the marker is inherited: `wa-operation` adds `spec.env` without `env_clear`,
    // so a shell started from a run's own shell hands `orchestrator` down to everything below it. An
    // empty value stops a host-started shell from passing on a marker the *host* did not just
    // decide - and the hook reads empty exactly as it reads unset (the human path). It does not
    // reach a process that never re-enters the host: a terminal, an external agent runtime or a node
    // restarted from an orchestrator shell keeps what it inherited. That residual trust boundary is
    // named in `.githooks/pre-commit` rather than papered over.
    spec.env.push((
        "WASM_AGENT_PROVENANCE".into(),
        crate::subagents::current_provenance().unwrap_or_default().to_string(),
    ));
    // ---- one root (`docs/ONEROOT.md`): scratch and the shared build cache -----------------------
    // Every child the node spawns - the `bash` tool, `operation start`, a build, a test, a landing,
    // a component build - gets `TMPDIR` inside the node's one root, so a temp file an agent writes is
    // something `wa clean` can find and one disk cap covers. Measured 12/11: `/tmp` was 98 % full on
    // the `work` node and broke deploys while the node's own state root sat at 0.4 GB.
    //
    // It is set unconditionally, including when the caller's environment already names a TMPDIR: the
    // promise is "everything an agent creates lives under one root", and a child that honoured an
    // inherited `/tmp` would break exactly that promise. When the root's `tmp/` cannot be created
    // there is nothing honest to point at, so the inherited value is left alone and the child is not
    // told a directory exists that does not.
    let tmp = wa_host_support::paths::tmp_dir();
    if tmp.is_dir() {
        let text = tmp.to_string_lossy().to_string();
        for name in ["TMPDIR", "TEMP", "TMP"] {
            spec.env.push((name.into(), text.clone()));
        }
    }
    // `CARGO_TARGET_DIR` IS DELIBERATELY NOT SET HERE.
    //
    // The operator's rule 2 asked for one shared build cache, and this was first implemented as one
    // `CARGO_TARGET_DIR` for every child. Measured on 12/11, that is **wrong**, not merely slow: with
    // two worktrees building into one target dir, cargo decided a `libwa_host_support-*.rlib` built from
    // the OTHER tree was fresh (its mtime was newer than this tree's source) and the build failed with
    // `cannot find function state_root in module wa_host_support::paths`. Cargo's freshness is
    // mtime-based and does not know which checkout a unit id came from (the measurement is in
    // `docs/ONEROOT.md`).
    //
    // Per-TREE target dirs under the root (`crate::disk::build_island`) are the safe shape, but they
    // cannot be chosen here: this function sees the child's *starting* directory, and `cd other-tree &&
    // cargo build` - an ordinary thing for an agent to type - would compile one tree into another tree's
    // island and re-create exactly that failure. So the node sets no CARGO_TARGET_DIR implicitly, and
    // the build entry points that DO know their tree (`scripts/lib/fast-binary.sh` for the fast path,
    // the deploy scripts for a deploy) point at the island themselves. `wa clean` judges those islands
    // by the tree named in `build/<island>/tree`. The dedupe a shared cache was meant to give needs a
    // compiler cache (sccache) with per-tree targets; it is proposed in `docs/ONEROOT.md`, not claimed.
    spec
}
/// The disk cap, checked before new heavy work starts (`docs/ONEROOT.md`, rule 4).
///
/// A build, a test or a deploy is what a full disk kills half way - `os error 112` in the middle of a
/// gate, after the clone, the turn and the resolution were paid for (`scripts/check-disk-floor.sh`
/// measured that on 30/9). So the same check runs where that work starts: `operation start` for a
/// supervised build/test/deploy, and the `bash` tool when its command is one. Under the cap it is one
/// measurement; over it, the node runs `wa clean` first and says so; still over, the work is refused
/// by name (`disk_cap`) with the numbers, rather than filling the disk.
///
/// Cheap kinds (`command`) are not gated: a `git status` on a full disk is not the thing that made
/// deploys fail, and refusing it would make the node unable to tell the operator what is going on.
fn cap_guard(command: &str) -> Result<(), String> {
    let kind = operation_kind(&Value::Null, command)?;
    if kind == "command" {
        return Ok(());
    }
    let root = wa_host_support::paths::state_root();
    crate::disk::guard_cached(&root, kind).map(|_| ())
}

fn launch_context(mut spec: Spec, context: &Value) -> Spec {
    spec.cwd_requested = context["requested"].as_str().map(String::from);
    spec.cwd_source = context["source"].as_str().map(String::from);
    spec.require_cwd = context["required"] == true;
    // WHOSE work this is (session isolation, finding 2). The session that asked travels with the
    // request (`lua/core/tools.lua`'s `launch_cwd`), so the record says which conversation owns the
    // operation and another session's `status`/`read`/`wait`/`cancel` can be refused by it. Empty is
    // left empty - an operation nobody names is nobody's, rather than everybody's.
    if spec.session.is_empty() {
        spec.session = context["session"].as_str().unwrap_or("").to_string();
    }
    spec
}
/// One tick of a long call's row (`docs/TOOL-PROGRESS.md`): the tail of the operation's two output
/// streams, parsed and published for the session-status-content row.
///
/// It runs on every pass of a wait loop, which is safe because `crate::tool_progress` bounds itself -
/// at most four writes a second and a grow-only byte cursor - and it reads the output *file*, which
/// `wa-operation` already wrote without the node's secrets. Nothing here is on the result path: the
/// state this loop returns is untouched by it.
fn progress_tick(state: &Value, tool: &str) {
    let Some(id) = state["operation_id"].as_str() else { return };
    let Some(stdout) = state["stdout_path"].as_str() else { return };
    // Whose call this is: the session that asked for the operation, recorded on it. The row is published
    // to that session's own file, so another session's reader can neither draw it nor read its output
    // (session isolation, finding 1). No session, no row: a call nobody can name is nobody's.
    let Some(owner) = state["session"].as_str().filter(|session| !session.is_empty()) else { return };
    let stderr = state["stderr_path"].as_str().unwrap_or("");
    let elapsed = state["elapsed_ms"].as_u64().unwrap_or(0) as f64 / 1000.0;
    crate::tool_progress::tick(id, tool, crate::tool_progress::now_epoch() - elapsed, stdout, stderr, owner);
}

pub fn foreground(
    program: &str,
    flag: &str,
    command: &str,
    cwd: &str,
    seconds: u64,
    context: &Value,
) -> Result<Value, String> {
    let launch = command_launch(program, flag, command)?;
    // Before the work is paid for, not after it dies on a full disk.
    cap_guard(command)?;
    let staged = launch.staged.clone();
    let id = manager()
        .start(launch_context(spec(
            &launch,
            cwd,
            seconds,
            format!("worker:{}", crate::serve::node_thread_id()),
            true,
            // A foreground shell: the run waits for this call, so it runs at the node own priority
            // (18/11 round 2, finding 9).
            false,
        ), context))
        .map_err(|e| e.to_string())?;
    // The name the reader knows this call by: the `bash` tool's own name, sent with the launch
    // (`lua/core/tools.lua`), so the row says `⟳ bash` and not `⟳ worker:7`.
    let tool = context["tool"].as_str().filter(|name| !name.is_empty()).unwrap_or("bash").to_string();
    loop {
        let mut state = manager()
            .wait(&id, Duration::from_millis(100))
            .map_err(|e| e.to_string())?;
        progress_tick(&state, &tool);
        if state["settled"] == true {
            crate::tool_progress::finish(&id);
            if state["error"] == "deadline_exceeded" {
                let stderr = state["stderr"].as_str().unwrap_or("");
                state["stderr"] = json!(format!("{stderr}\n{}", deadline_note(seconds, &state)));
            }
            if let Some(path) = staged.as_ref() {
                state["staged_script"] = json!(path.to_string_lossy());
                state["staged_script_note"] = json!("the command was too long for the Windows command line and ran from this staged file; $0 is the file path");
                // Settled means the shell has finished, so the staged bytes can go. A failure
                // here is not the caller's problem: the file stays under ~/.wasm-agent/commands.
                let _ = std::fs::remove_file(path);
            }
            return Ok(state);
        }
        // The shell exited leaving live descendants, so they were adopted rather than
        // failed. Return the receipt now: the operation keeps running under the
        // supervisor, and the caller is told which process it now owns.
        if state["promoted"] == true
            && (state["output_streams_closed"] == true
                || state["output_idle_ms"].as_u64().unwrap_or(0)
                    >= wa_operation::COMMAND_OUTPUT_IDLE_MS)
        {
            state["foreground_return_elapsed_ms"] = state["elapsed_ms"].clone();
            if let Some(path) = staged.as_ref() {
                // Still running: the shell may read this file again, so it stays until settled.
                state["staged_script"] = json!(path.to_string_lossy());
                state["staged_script_note"] = json!("the command was too long for the Windows command line and ran from this staged file; $0 is the file path, and the file is kept while the operation runs");
            }
            crate::tool_progress::finish(&id);
            return Ok(command_result(manager(), &id, state));
        }
        if state["overdue"] == true {
            crate::tool_progress::finish(&id);
            let _ = manager().cancel(&id);
            return Ok(
                json!({"operation_id":id,"ok":false,"code":-1,"error":"operation_supervisor_overdue","cleanup":"unknown","output_complete":false}),
            );
        }
        // A cancelled run or child cancels its operation too, and stays attached
        // until the operation actually settles: returning while it still runs would
        // let the effect outlive the execution that owns it.
        if crate::host::run_cancel_requested() {
            crate::tool_progress::finish(&id);
            let _ = manager().cancel(&id);
            let cleanup = std::time::Instant::now() + Duration::from_millis(1000);
            while std::time::Instant::now() < cleanup {
                let stopped = manager()
                    .wait(&id, Duration::from_millis(50))
                    .map_err(|e| e.to_string())?;
                if stopped["settled"] == true {
                    return Ok(json!({"operation_id":id,"ok":false,"error":"run_cancelled",
                        "state":stopped["state"],"cleanup":"settled","output_complete":stopped["output_complete"]}));
                }
            }
            return Ok(json!({"operation_id":id,"ok":false,"error":"run_cancelled",
                "cleanup":"unknown","output_complete":false}));
        }
        // This is the waiting interpreter observing the supervisor, not a helper beating forever.
        crate::serve::beat();
    }
}
/// Who is asking, and how far they may reach.
///
/// An operation's `owner` has been recorded since the runtime existed and was never compared with the
/// caller: `list` answered with every operation on the node, and `status`, `read`, `wait`, `await` and
/// `cancel` answered for any id - and the ids are guessable (`op-<micros>-<pid>-<n>`), so "you cannot
/// find it" was not a boundary either (session isolation, finding 2). Lua decides *who* the session is
/// and whether it holds a node scope (`lua/core/session_scope.lua`); this decides what the runtime does
/// with that answer, which is the half that must not be skippable by a caller that forgets.
pub(crate) struct Caller { session: String, node: bool, owner: String }

impl Caller {
    pub(crate) fn from(args: &Value) -> Self {
        Self {
            session: args["session"].as_str().unwrap_or("").to_string(),
            node: args["node_scope"] == true,
            // The runtime owner this caller started work under (lua/core/tools.lua stamps
            // ctx.session_id or the user id; a node tool names its own). It is the cap key and the
            // ownership key for a caller that is not a session (item 7, round 2).
            owner: args["owner"].as_str().unwrap_or("").to_string(),
        }
    }
    /// The node's own supervisor (the sentinel's node-wide reads) names no session and no node scope:
    /// it is the one caller that is not a session at all.
    pub(crate) fn node_wide(&self) -> bool { self.node }
    /// An operation is the caller's when the caller IS a session and the operation recorded that same
    /// session. An operation whose session is empty (or that only recorded the runtime's `owner`) belongs
    /// to nobody the caller can claim: unknown is not yes.
    pub(crate) fn owns(&self, state: &Value) -> bool {
        if self.node { return true; }
        let owner = state["session"].as_str().unwrap_or("");
        // A session may act on what it recorded, and on nothing else - and a session can never claim an
        // operation that recorded no session at all.
        if self.session.is_empty() {
            // A SESSIONLESS CALLER IS NOT A NODE-WIDE CALLER (item 7, round 2). Round 1 answered "every
            // operation that recorded no session is mine", which is the same "everything on the node"
            // answer this finding removed, only spelled with an empty session. The honest rule is the
            // runtime OWNER: a sessionless caller owns the work started under its own owner (worker:N, a
            // read-MCP session, a user id) and nothing else. A caller that names no owner at all owns the
            // rows that also name none - which is the node's own supervisor and nothing wider.
            let runtime_owner = state["owner"].as_str().unwrap_or("");
            if self.owner.is_empty() {
                // A caller that names NO owner is this process's own tooling (a script, host.exec, the
                // sentinel). It owns the rows nobody named: an empty owner, and the runtime's own
                // foreground identity (worker:<n>), which no caller can choose and no session can be. It
                // still does not own a row a session named, nor one another NAMED owner started (a
                // read-MCP session, a user id, a worker of another process).
                // The runtime's own foreground identity counts only for a row that named NO session: a
                // bash a session started is promoted with owner worker:<n> AND its session, and it is that
                // session's row, not the node tooling's.
                // A `worker:<n>` row belongs to the caller only when <n> is the node thread the
                // caller is RUNNING ON (item 2, round 5). Round 2/4 matched any `worker:*`: one
                // sessionless script owned every thread's foreground shell, on a node where several
                // scripts run at once. The identity is the caller's own and no caller can choose it,
                // so this is narrower, not wider - measured against the four rows that depend on it
                // (test-exec-timeout, test-bash-long-command, test-workspace-cwd, this mission's row).
                let own_thread = format!("worker:{}", crate::serve::node_thread_id());
                return runtime_owner.is_empty()
                    || (runtime_owner.starts_with("worker:") && owner.is_empty()
                        && runtime_owner == own_thread);
            }
            return runtime_owner == self.owner;
        }
        owner == self.session
    }
    /// The refusal, named: what it is, whose it is, and the one way to reach it.
    pub(crate) fn refusal(&self, id: &str) -> Value {
        json!({
            "operation_id": id,
            "error": "operation_not_yours",
            "effect": "none",
            "not_your_operation": true,
            "note": format!("operation {id} is not your operation: another session owns it. Only an explicit node scope (scope:\"node\", operator only) may read or act on it."),
        })
    }
}

/// Split the node's operations into the caller's and a COUNT of everybody else's.
///
/// ONLY UNSETTLED WORK COUNTS (session isolation, item 3 round 4). A settled operation is not running
/// anywhere, and counting it made `node: N ops elsewhere` a lifetime total that never went down. The
/// sentence says "ops", so the count is operations and not sessions either: four unsettled operations in
/// one other session are four, which is exactly what a per-session progress file could not say (it counted
/// one file per session). One rule, used by `list` and by `health_scope`, pinned by
/// `a_settled_operation_is_not_counted_elsewhere`.
///
/// SETTLEMENT NARROWS THE COUNT, NOT THE CALLER'S OWN LIST (item 1, round 5). Round 4 skipped every
/// settled row before it asked whose it was, so the caller's own FAILED operation vanished from its own
/// `list` the moment it settled - and a failure is the one row a caller must be able to read
/// back. Ownership decides what is mine; `settled` decides only whether it counts as running
/// elsewhere.
pub(crate) fn split_elsewhere(caller: &Caller, items: &[Value]) -> (Vec<Value>, usize) {
    let mut mine = Vec::new();
    let mut elsewhere = 0usize;
    for state in items {
        if caller.owns(state) {
            // MINE IS OWNERSHIP'S ANSWER, SETTLED OR NOT (item 1, round 5): a caller reads back what it
            // ran, and its own failed operation is the row it most needs.
            mine.push(state.clone());
        } else if state["settled"] != true {
            // ELSEWHERE IS A COUNT OF WORK, so a settled row is not counted: it is running nowhere.
            elsewhere += 1;
        }
    }
    (mine, elsewhere)
}

/// `Some(state)` when the caller may act on `id`, `Some` from `snapshot` only if it owns it. `None`
/// means "not yours" and the caller answers with [Caller::refusal].
pub(crate) fn owned(caller: &Caller, id: &str) -> Result<Option<Value>, String> {
    let state = manager().snapshot(id).map_err(|e| e.to_string())?;
    Ok(if caller.owns(&state) { Some(state) } else { None })
}

pub fn control(action: &str, args: &Value, shell: &(String, String)) -> Result<Value, String> {
    let id = args["id"].as_str().unwrap_or("");
    let caller = Caller::from(args);
    let result = match action {
        "start" => {
            if args.get("replay_of").is_some(){return Err("operation_replay_forbidden: inspect original and make a separately authorized decision".into());}
            let owner = args["owner"].as_str().unwrap_or("").to_string();
            // Backgrounded unless the caller says it waits for this call: an explicit start hands back a
            // receipt and the caller moves on, and a code-mode pending call the script is actively
            // awaiting passes background=false so it keeps the node own priority (18/11 round 2,
            // finding 9).
            let background = args["background"].as_bool().unwrap_or(true);
            let command_hint = args["command"].as_str().unwrap_or("");
            let requested_seconds = args["timeout_seconds"].as_u64();
            let default_kind = if requested_seconds.is_none() {
                Some(operation_kind(args, command_hint)?)
            } else {
                // An explicit kind with an explicit timeout is still validated, so a typo cannot look applied.
                if args["kind"].as_str().is_some_and(|kind| !kind.is_empty()) {
                    let _ = operation_kind(args, command_hint)?;
                }
                None
            };
            let seconds = requested_seconds
                .unwrap_or_else(|| default_operation_timeout_seconds(default_kind.unwrap_or("command")));
            // The disk cap, before a supervised build/test/deploy is admitted (docs/ONEROOT.md).
            cap_guard(command_hint)?;
            let cwd=args["cwd"].as_str().unwrap_or("");
            let mut staged_script: Option<std::path::PathBuf> = None;
            let launch=if let Some(program)=args["program"].as_str() {
                if args.get("command").is_some() {return Err("program_and_command_are_exclusive".into());}
                let name=if cfg!(windows) && !program.ends_with(".exe") {format!("{program}.exe")} else {program.to_string()};
                let executable=if std::path::Path::new(&name).is_absolute() {
                    if !std::path::Path::new(&name).is_file() {return Err("program_not_found".into());}
                    name
                } else {
                    if name.contains('/') || name.contains('\\') {return Err("program_requires_native_absolute_path_or_path_name".into());}
                    crate::host::which_on_path(&name).ok_or("program_not_found_on_path")?
                };
                let argv=args["args"].as_array().ok_or("program_args_required")?.iter()
                    .map(|arg|arg.as_str().map(String::from).ok_or("program_args_must_be_strings"))
                    .collect::<Result<Vec<_>,_>>()?;
                configure_spec(Spec::command(executable,argv),cwd,seconds,owner,false,background)
            } else {
                let command=args["command"].as_str().filter(|s|!s.is_empty()).ok_or("command_required")?;
                let prepared = command_launch(&shell.0, &shell.1, command)?;
                staged_script = prepared.staged.clone();
                spec(
                    &prepared,
                    cwd,
                    seconds,
                    owner,
                    false,
                    background,
                )
            };
            // `vault_env` ({ENV: entry}): the kernel puts a node-vault entry in the child's environment, so a
            // connector's credential is used by reference and never passes through Lua, a request file or a
            // transcript (operator 17/11 "its credential should be in the vault"). Only the kernel's own
            // callers send it (the MCP client and session); the generic operation route strips it.
            let mut launch = launch;
            let vault_launch = args.get("vault_env").and_then(|value| value.as_object()).is_some();
            let mut verified: VerifiedFiles = Vec::new();
            if let Some(map) = args.get("vault_env").and_then(|value| value.as_object()) {
                // The approval comes FIRST: a launch whose program, arguments or scripts no longer
                // match what the operator approved reads no value at all (docs/VAULT.md). It answers the
                // bytes it verified, so the same bytes are checked again after the spawn.
                verified = approval_problem(args.get("vault_approval").unwrap_or(&Value::Null), &launch)?;
                for (name, entry) in map {
                    let valid = !name.is_empty() && name.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
                        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
                    if !valid { return Err(format!("vault_env_invalid_name:{name}")); }
                    let entry = entry.as_str().ok_or("vault_env_entry_must_be_a_string")?;
                    let value = vault_value(entry)?;
                    launch.env.retain(|(key, _)| key != name);
                    launch.env.push((name.clone(), value));
                }
            }
            // The command a vault launch's child actually SPAWNS lives in the request file, not on this
            // command line: check it against the same approval and seal the exact bytes the child must
            // read (the first hole of this round, docs/VAULT.md).
            seal_request(&mut launch, args.get("vault_approval").unwrap_or(&Value::Null), vault_launch)?;
            let mut admitted = launch_context(launch, &args["_launch_cwd"]);
            // A CONTROL start (the node's own SHORT read) is the only kind admitted into the two slots
            // no workload may hold (item 7, round 2). lua/core/tools.lua clears this key on a model call,
            // so it comes from the node's read paths only.
            //
            // AND SHORT IS PART OF THE RULE (session isolation, item 4 round 4): the reserve is what keeps
            // the node able to ask a question while every workload slot is busy, so a start that runs for
            // longer than CONTROL_MAX_SECONDS cannot hold one - a read-MCP session (3600 s) parked two
            // reserved slots for an hour in round 3. A long start that asks for the reserve is demoted to
            // a workload and TOLD, because a silently changed admission is a misleading result.
            let asked_control = args["control"] == true;
            let control_refused = reserve_refused(asked_control, seconds);
            admitted.control = asked_control && !control_refused;
            // The session that asked owns what it started, even when the launch context did not carry it
            // (`launch_cwd` does; a caller that passes its own provenance may not).
            if admitted.session.is_empty() {
                admitted.session = args["session"].as_str().unwrap_or("").to_string();
            }
            let id = manager()
                .start(admitted)
                .map_err(|e| e.to_string())?;
            // The files were hashed BEFORE this spawn and the child opens them after it: a rewrite that
            // lands in that window is caught by neither hash alone. The same bytes are hashed again now,
            // and a mismatch kills the operation instead of returning its result (this round's fourth
            // finding; docs/VAULT.md states the residual window rather than denying it).
            if let Some(problem) = recheck_after_spawn(&verified) {
                let _ = manager().cancel(&id);
                return Err(problem);
            }
            let state = manager().snapshot(&id).map_err(|e| e.to_string())?;
            let mut receipt = json!({"operation_id":id,"state":"accepted","settled":false,"note":"Launch receipt, not execution success. Observe this operation; do not launch it again. Keep background commands in the foreground of this shell (or use wait)."});
            // No silent deadline. A caller that named one gets `timeout_source: caller`; a caller that did
            // not gets the kind's default AND a sentence saying which default was used and how to raise it.
            match default_kind {
                Some(kind) => {
                    receipt["timeout_source"] = json!("default");
                    receipt["timeout_kind"] = json!(kind);
                    receipt["timeout_ms"] = json!(seconds * 1000);
                    receipt["timeout_notice"] = json!(format!(
                        "no timeout_seconds was given: this {kind} operation uses the {kind} default of {seconds}s. Pass timeout_seconds (1-86400) to set it explicitly; when it runs out the operation is killed and reported deadline_exceeded."));
                }
                None => {
                    receipt["timeout_source"] = json!("caller");
                    receipt["timeout_ms"] = json!(seconds * 1000);
                }
            }
            if let Some(path) = staged_script.as_ref() {
                receipt["staged_script"] = json!(path.to_string_lossy());
                receipt["staged_script_note"] = json!("the command was too long for the Windows command line and ran from this staged file; $0 is the file path, the script is not removed while the operation may still read it");
            }
            if control_refused {
                receipt["control_refused"] = json!(format!(
                    "a start of {seconds}s is a workload, not a control call: the two reserved slots are kept for short calls (status, list, cancel, short reads, at most {}s)",
                    wa_operation::CONTROL_MAX_SECONDS));
            }
            for key in ["cwd", "cwd_requested", "cwd_source", "effective_cwd", "cwd_substitution", "cwd_note"] {
                if let Some(value) = state.get(key) { receipt[key] = value.clone(); }
            }
            return Ok(receipt);
        }
        // Every operation this session owns, and a count of the ones it does not. It used to answer
        // with every operation on the node, which is how one session's build showed up as another's
        // (session isolation, finding 2).
        "list" => {
            let items = manager().list().as_array().cloned().unwrap_or_default();
            let (mine, elsewhere) = split_elsewhere(&caller, &items);
            let count = mine.len();
            let note = if elsewhere == 0 { String::new() } else {
                format!("{elsewhere} other operation(s) on this node belong to other sessions; an explicit node scope (scope:\"node\", operator only) is the only way to see them")
            };
            return Ok(json!({"ok":true,"operations":mine,"operations_count":count,
                "operations_elsewhere":elsewhere,"node_scope":caller.node_wide(),"note":note}));
        }
        // Relevance is a question about a *path*; `"*"` is the question about the whole node, so it is
        // the operator's alone (session isolation, findings 2 and 8).
        "relevant" => {
            let cwd = args["cwd"].as_str().unwrap_or("");
            // `"*"` is the whole node, so it is the node scope's question and nobody else's - not a
            // session's, and not a sessionless caller's either: a caller that is not a session is not
            // node-wide (item 7, round 2). The release path asks about ONE path and needs no scope.
            if cwd == "*" && !caller.node_wide() {
                return Ok(json!({"ok":false,"error":"relevant_node_scope_required","effect":"none",
                    "note":"relevant with cwd:\"*\" asks about every path on the node: it needs an explicit node scope (scope:\"node\", operator only)"}));
            }
            manager().relevant(cwd, args["after"].as_str().unwrap_or(""), args["limit"].as_u64().unwrap_or(64).min(256) as usize,
                    caller.session.as_str(), caller.node_wide())
                .map(|mut answer| {
                    // The session travels into relevance so an operation that recorded no directory is
                    // relevant only to the session that ran it (session isolation, finding 8).
                    answer["session"] = json!(caller.session);
                    answer
                })
        }
        "index" => manager().import_index(args["evidence"].as_str().unwrap_or("")),
        "reconcile" => {
            // A reconciliation settles an operation whose owning PROCESS is gone - there is no session
            // left to compare against, and the caller is deciding about effects it did not run. That is
            // the operator's action, so it needs the explicit node scope, which is audited in Lua
            // (session isolation, finding 2).
            // NOT EVEN A SESSIONLESS CALLER reconciles without the scope (item 7, round 2): settling an
            // operation nobody is left to answer for is the operator's act, and the node's own reconciler
            // process holds the scope on its own behalf (it passes node_scope itself, and the audit line
            // names the tool). What the empty session bought was a path around the decision.
            if !caller.node_wide() {
                return Ok(json!({"ok":false,"error":"reconcile_node_scope_required","effect":"none",
                    "note":"reconciling settles an operation whose owner process is gone, so the request names no live session: it needs an explicit node scope (scope:\"node\", operator only)"}));
            }
            manager().reconcile(args)
        }
        "quarantine_retire" => {
            if crate::serve::in_turn() || std::env::var("WASM_AGENT_IN_TURN").as_deref()==Ok("1") || std::env::var("WA_QUARANTINE_EXECUTOR").as_deref()!=Ok("1") {return Err("quarantine_requires_explicit_external_executor".into());}
            manager().quarantine_retire(args)
        },
        "legacy_adjudicate" => {
            if crate::serve::in_turn() || std::env::var("WASM_AGENT_IN_TURN").ok().as_deref()==Some("1") || std::env::var("WA_LEGACY_EXTERNAL_EXECUTOR").ok().as_deref()!=Some("1") {return Err("legacy_adjudication_requires_external_reviewed_executor".into());}
            manager().adjudicate_legacy(args)
        },
        "allocation_safety" => manager().allocation_safety(args),
        "identity" => manager().identity(),
        // Owned by the session that started it, or refused by name (session isolation, finding 2).
        "status" => match owned(&caller, id)? {
            Some(state) => Ok(state),
            None => Ok(caller.refusal(id)),
        },
        // Nobody is waiting for this operation any more: lower its CPU priority now that the fact is
        // known (18/11 round 3, item 5). The answer is the operation's state, with the priority it now
        // runs at; a failure to renice is recorded on that state, never turned into a failed call.
        // The same ownership rule as every other action: another session's operation is refused by name.
        "background" => match owned(&caller, id)? {
            Some(_) => manager().background(id),
            None => Ok(caller.refusal(id)),
        },
        "await" => {
            if owned(&caller, id)?.is_none() { return Ok(caller.refusal(id)); }
            // Foreground bash can complete while its adopted descendants remain supervised.
            // Default to the command boundary for those operations; explicit operation start
            // and wait_for=settled retain full process-tree settlement semantics.
            let wait_for = args["wait_for"].as_str().unwrap_or("command");
            if wait_for != "command" && wait_for != "settled" {
                return Err("invalid_wait_for:expected_command_or_settled".into());
            }
            let tool = args["tool"].as_str().filter(|name| !name.is_empty()).unwrap_or("operation");
            // THE WAIT IS HONOURED, and it is BOUNDED (verification r2, MUST 3).
            //
            // This loop used to ignore wait_ms entirely: it returned only when the operation settled, so a
            // relayed await held the relay connection and a peer slot until the RELAY deadline (~35 s) and
            // then reported a timeout - the held-slot pattern of the 19/11 storm. wait_ms is the caller's
            // own bound, clamped to the operation tool's documented maximum (10 s) and defaulting to 1 s;
            // past it the answer is the state as it stands, which is exactly what action "wait" answers.
            let budget = Duration::from_millis(args["wait_ms"].as_u64().unwrap_or(1000).min(10_000));
            let started = std::time::Instant::now();
            loop {
                let left = budget.saturating_sub(started.elapsed());
                let state = manager()
                    .wait(id, left.min(Duration::from_millis(250)))
                    .map_err(|e| e.to_string())?;
                progress_tick(&state, tool);
                if state["settled"] == true {
                    crate::tool_progress::finish(id);
                    return Ok(state);
                }
                if wait_for == "command"
                    && state["promoted"] == true
                    && (state["output_streams_closed"] == true
                        || state["output_idle_ms"].as_u64().unwrap_or(0)
                            >= wa_operation::COMMAND_OUTPUT_IDLE_MS)
                {
                    return Ok(command_result(manager(), id, state));
                }
                if crate::host::run_cancel_requested() {
                    return Ok(json!({"operation_id":id,"ok":false,"settled":false,
                        "error":"await_interrupted","outcome":"still_running",
                        "note":"The wait was interrupted; the independently supervised operation was not canceled. Inspect it or await again. Do not rerun it."}));
                }
                if state["overdue"] == true {
                    return Ok(json!({"operation_id":id,"ok":false,"settled":false,
                        "error":"operation_supervisor_overdue","outcome":"unknown",
                        "note":"No replay or inferred success. Inspect or explicitly cancel/recover."}));
                }
                if started.elapsed() >= budget {
                    // The caller's own wait is over: answer the state as it stands. A caller that wants to
                    // keep watching asks again, and no call holds a relay connection while it waits.
                    return Ok(state);
                }
                crate::serve::beat();
            }
        }
        "cancel" => {
            if owned(&caller, id)?.is_none() { return Ok(caller.refusal(id)); }
            let stopped = manager().cancel(id);
            // A cancelled call is over: its row goes with it.
            crate::tool_progress::finish(id);
            stopped
        }
        // A caller polling an operation is the other place that owns its tail for a while (the
        // `operation` tool's own loop, the window's `/operation` read): refresh the row while it
        // waits, so a long call that the model is watching says what it is doing.
        "wait" => {
            if owned(&caller, id)?.is_none() { return Ok(caller.refusal(id)); }
            let budget = Duration::from_millis(args["wait_ms"].as_u64().unwrap_or(1000).min(10000));
            let started = std::time::Instant::now();
            loop {
                let state = manager()
                    .wait(id, budget.min(Duration::from_millis(250)))
                    .map_err(|e| e.to_string())?;
                progress_tick(&state, args["tool"].as_str().filter(|name| !name.is_empty()).unwrap_or("operation"));
                if state["settled"] == true { crate::tool_progress::finish(id); return Ok(state); }
                if started.elapsed() >= budget { return Ok(state); }
            }
        }
        // An operation's output IS its content: reading another session's stdout is the leak this whole
        // check exists to close, so the read is refused before a byte of the file is opened.
        "read" => match owned(&caller, id)? {
            Some(_) => manager().read(
                id,
                args["stream"].as_str().unwrap_or("stdout"),
                args["offset"].as_u64().unwrap_or(0),
                args["limit"].as_u64().unwrap_or(8192) as usize,
            ),
            None => Ok(caller.refusal(id)),
        },
        _ => return Err("unknown_operation_action".into()),
    };
    result.map_err(|e| e.to_string())
}
/// One operation as a viewer may see it: the numbers, never the output. `session` is the conversation
/// that owns it, so a viewer can tell its own work from the node's without reading anybody's tail.
fn health_row(state: &Value) -> Value {
    json!({"operation_id":state["operation_id"],"owner":state["owner"],"session":state["session"],
        "state":state["state"],"elapsed_ms":state["elapsed_ms"],"timeout_ms":state["timeout_ms"],
        "cleanup_budget_ms":state["cleanup_budget_ms"],"overdue":state["overdue"],
        "output_bytes":state["output_bytes"]})
}

/// The node's own view: every unsettled operation. This is the supervisor's question ("is anything
/// overdue?") and it names no viewer, so it stays node-wide - the sentinel reads it, and the id/owner
/// it carries is a fact about this node, not about a session's work.
pub fn health() -> Value {
    let entries = manager().list();
    json!(entries.as_array().unwrap().iter().filter(|s|s["settled"]!=true).map(health_row).collect::<Vec<_>>())
}

/// One session's view: the operations IT owns, and how many others are running.
///
/// `/health` answered with every operation on the node and no owner filter, so a window drew another
/// session's operation as its own - and, with one row per node (finding 1), the tail of its output too
/// (session isolation, finding 9). The aggregate is a count: no id, no owner, no session of anybody
/// else's.
pub fn health_scope(session: &str) -> Value {
    health_scope_for(session, true, "")
}

/// The same answer, for the caller the ROUTE decided this request is (session isolation, item 6 round 4).
///
/// `node_wide` is not read from the query string any more: `lua/core/server.lua`'s
/// `wa_health_scope` resolves the request's credential and says which view it may have. A caller with no
/// credential at all is the node supervisor's own view - the sentinel's "is anything overdue?" question -
/// and an authenticated caller with no conversation named sees the work under its own owner, never the
/// node's.
pub fn health_scope_for(session: &str, node_wide: bool, owner: &str) -> Value {
    let caller = Caller { session: session.to_string(), node: node_wide, owner: owner.to_string() };
    // The same rule as `list`: only unsettled operations are elsewhere, and one rule serves both.
    let items = manager().list().as_array().cloned().unwrap_or_default();
    let (ops, elsewhere) = split_elsewhere(&caller, &items);
    // /health IS A NOW-VIEW: the caller's own operations THAT ARE RUNNING. `list` keeps a settled
    // row so a caller can read back what it ran (item 1, round 5); a health page that listed finished
    // work would answer "what is this node doing" with its history.
    let mine: Vec<Value> = ops.iter().filter(|s| s["settled"] != true).map(health_row).collect();
    json!({"session": session, "operations": mine, "operations_elsewhere": elsewhere,
        "operations_scope": if session.is_empty() { "node" } else { "session" }})
}

/// Is a start that ASKED for the reserved control slots refused them, because it is not short?
///
/// The reserve keeps the node able to ask a short question while every workload slot is busy, so a start
/// that lives longer than `wa_operation::CONTROL_MAX_SECONDS` is a workload however it asks (session
/// isolation, item 4 round 4). One rule, one function, pinned by
/// `a_long_start_cannot_take_the_reserved_control_slots`.
pub(crate) fn reserve_refused(asked_control: bool, seconds: u64) -> bool {
    asked_control && seconds > wa_operation::CONTROL_MAX_SECONDS
}

/// The count the progress row draws: the OTHER sessions' unsettled operations, for `session`.
///
/// The editor's row cannot reach this manager itself (wa-term is a leaf that knows nothing of the
/// runtime), so the host asks here and hands the number to `wa_term::tool_progress::current`
/// (session isolation, item 3 round 4). A settled operation is not counted, and one session holding four
/// unsettled operations is counted as four.
pub fn elsewhere_count(session: &str) -> usize {
    let caller = Caller { session: session.to_string(), node: session.is_empty(), owner: String::new() };
    let items = manager().list().as_array().cloned().unwrap_or_default();
    split_elsewhere(&caller, &items).1
}

/// What a deadline can honestly say.
///
/// This message used to assert a cause - "a call to this node's own busy session cannot serve
/// itself; use an independent route" - which the record cannot support: everything that outlives
/// its bound lands here, including a read-only `grep` that never addressed this node at all. A
/// printed cause is a fact-shaped thing, so it was quoted onward as a finding; a false one costs
/// the round twice. What the operation *does* know is where its time went - `timing` is measured
/// in phases - so the note reports exactly that, and nothing it did not measure.
fn deadline_note(seconds: u64, state: &Value) -> String {
    let phase = |name: &str| state["timing"][name].as_u64();
    let mut phases = Vec::new();
    for (name, label) in [
        ("setup_ms", "setup"),
        ("spawn_ms", "spawn"),
        ("execution_ms", "executing"),
        ("drain_cleanup_ms", "cleanup"),
    ] {
        if let Some(ms) = phase(name) {
            phases.push(format!("{label} {ms}ms"));
        }
    }
    let account = if phases.is_empty() {
        "no phase breakdown was recorded".to_string()
    } else {
        phases.join(", ")
    };
    match state["elapsed_ms"].as_u64() {
        Some(total) => format!(
            "the command did not finish within {seconds}s; its operation was terminated after {total}ms ({account})."
        ),
        None => format!(
            "the command did not finish within {seconds}s; its operation was terminated ({account})."
        ),
    }
}

#[cfg(test)]
mod elsewhere_count_tests {
    use super::{split_elsewhere, Caller};
    use serde_json::json;

    /// Item 3 (round 4): "elsewhere" counts the OTHER sessions' UNSETTLED OPERATIONS.
    ///
    /// It used to count live progress files - one per session - so four unsettled operations in one
    /// other session were announced as "node: 1 op elsewhere", and a settled operation went on being
    /// counted for as long as its file survived. A settled operation is running nowhere.
    #[test]
    fn a_settled_operation_is_not_counted_elsewhere() {
        let caller = Caller { session: "session-a".into(), node: false, owner: String::new() };
        let items = vec![
            json!({"operation_id":"op-1","session":"session-b","settled":false}),
            json!({"operation_id":"op-2","session":"session-b","settled":false}),
            json!({"operation_id":"op-3","session":"session-b","settled":false}),
            json!({"operation_id":"op-4","session":"session-b","settled":false}),
            json!({"operation_id":"op-5","session":"session-b","settled":true}),
            json!({"operation_id":"op-6","session":"session-a","settled":false}),
        ];
        let (mine, elsewhere) = split_elsewhere(&caller, &items);
        assert_eq!(elsewhere, 4, "four unsettled operations of ONE other session are four");
        assert_eq!(mine.len(), 1, "and the caller's own unsettled operation is its own");
        assert_eq!(mine[0]["operation_id"], json!("op-6"));
    }

    /// Item 4 (round 4): only SHORT control calls may take the reserved slots.
    ///
    /// Round 3 marked the read-MCP session `control=true` and it lives 3600 s, so it could hold both
    /// reserved slots for an hour and the "cancel the runaway" path had nothing left to run in. A long
    /// start is a workload, whatever it asks for.
    #[test]
    fn a_long_start_cannot_take_the_reserved_control_slots() {
        use super::reserve_refused;
        assert!(reserve_refused(false, 3600) == false, "a workload takes no reserve anyway");
        assert!(reserve_refused(true, 5) == false, "a short control call keeps the reserve");
        assert!(reserve_refused(true, wa_operation::CONTROL_MAX_SECONDS) == false, "the bound itself is short");
        assert!(reserve_refused(true, wa_operation::CONTROL_MAX_SECONDS + 1), "one second past it is a workload");
        assert!(reserve_refused(true, 3600), "the read-MCP session's 3600 s start is a workload");
    }

    /// A node-wide caller owns everything, and a settled row is still not running anywhere: the count
    /// stays a count of WORK, not of the caller's reach.
    ///
    /// Item 1 (round 5) moved the settled filter from the WHOLE answer to the count alone, so this row
    /// now owns BOTH: it reads back the one it ran - settled rows included - and still counts zero
    /// elsewhere, because a settled operation is running nowhere.
    #[test]
    fn a_node_wide_caller_still_counts_only_unsettled_work_elsewhere() {
        let caller = Caller { session: "".into(), node: true, owner: String::new() };
        let items = vec![
            json!({"operation_id":"op-1","session":"session-b","settled":false}),
            json!({"operation_id":"op-2","session":"session-b","settled":true}),
        ];
        let (mine, elsewhere) = split_elsewhere(&caller, &items);
        assert_eq!(mine.len(), 2, "a node-wide caller owns every row, settled or not");
        let ids: Vec<&str> = mine.iter().filter_map(|s| s["operation_id"].as_str()).collect();
        assert!(ids.contains(&"op-1") && ids.contains(&"op-2"), "both ids are listed: {ids:?}");
        assert_eq!(elsewhere, 0, "and nothing is elsewhere to it");
    }

    /// ITEM 1 (round 5): a caller's OWN SETTLED OPERATION STAYS IN ITS OWN LIST.
    ///
    /// Round 4's `split_elsewhere` skipped every settled row before it asked whose it was, so a session
    /// that ran a command which FAILED could not read the failure back: it vanished from `list` the
    /// instant it settled. The count is the only thing settlement narrows.
    #[test]
    fn the_callers_own_failed_operation_stays_in_its_list() {
        let caller = Caller { session: "session-a".into(), node: false, owner: String::new() };
        let items = vec![
            json!({"operation_id":"op-failed","session":"session-a","state":"failed","settled":true}),
            json!({"operation_id":"op-theirs-settled","session":"session-b","state":"failed","settled":true}),
            json!({"operation_id":"op-theirs-live","session":"session-b","state":"running","settled":false}),
        ];
        let (mine, elsewhere) = split_elsewhere(&caller, &items);
        assert_eq!(mine.len(), 1, "exactly the caller's own row is its list");
        assert_eq!(mine[0]["operation_id"], json!("op-failed"));
        assert_eq!(mine[0]["state"], json!("failed"), "and it still says how it failed");
        assert_eq!(elsewhere, 1, "another session's SETTLED row is not counted as running");
    }

    /// The Fleet View's incident line needs an id, and a settled operation row carries
    /// `operation_id` - never `id`. The incident read `entry.id`, so a real failure was announced as
    /// "operation ? settled as failed" (item 1, round 5).
    #[test]
    fn a_settled_operation_row_names_its_id_as_operation_id() {
        let caller = Caller { session: "session-a".into(), node: false, owner: String::new() };
        let items = vec![json!({"operation_id":"op-failed","session":"session-a","state":"failed",
            "settled":true,"finished_at":1750000000000u64})];
        let (mine, _) = split_elsewhere(&caller, &items);
        assert_eq!(mine[0]["operation_id"], json!("op-failed"));
        assert!(mine[0].get("id").is_none(), "the row has no bare `id` field to read instead");
    }

    /// ITEM 2 (round 5): a sessionless, ownerless caller owns a `worker:<n>` row ONLY when <n> is
    /// the node thread it is itself running on.
    ///
    /// Rounds 2-4 matched `worker:*`, so ONE sessionless script owned EVERY thread's foreground
    /// shell on a node where several scripts run at once. Narrowing it to the caller's own thread
    /// keeps the row usable - the same caller must cancel and read back what host.exec adopted -
    /// without handing it a sibling thread's work. Measured: the rows that depend on it run green
    /// (test-exec-timeout 39 checks, test-bash-long-command 10, this mission's row 132).
    #[test]
    fn a_sessionless_caller_owns_only_its_own_threads_worker_row() {
        let own = format!("worker:{}", crate::serve::node_thread_id());
        let caller = Caller { session: String::new(), node: false, owner: String::new() };
        let mine = json!({"operation_id":"op-own","owner":own,"session":"","settled":false});
        assert!(caller.owns(&mine), "the caller's own thread's row is its own: {own}");
        let sibling = json!({"operation_id":"op-sibling","owner":"worker:424242","session":"","settled":false});
        assert!(!caller.owns(&sibling), "another node thread's row is NOT owned by an ownerless caller");
        let named = json!({"operation_id":"op-read-mcp","owner":"mcp-read-session","session":"","settled":false});
        assert!(!caller.owns(&named), "and neither is a row another NAMED owner started");
        let empty = json!({"operation_id":"op-none","owner":"","session":"","settled":false});
        assert!(caller.owns(&empty), "a row nobody named is the node tooling's own");
        let a_session = json!({"operation_id":"op-sess","owner":own,"session":"session-a","settled":false});
        assert!(!caller.owns(&a_session), "a session's row is that session's, whatever thread adopted it");
    }
}

#[cfg(test)]
mod deadline_note_tests {
    use super::deadline_note;
    use serde_json::json;

    #[test]
    fn child_shell_is_marked_in_turn_and_cannot_request_installation() {
        use crate::subagents::{TaskContext,Provenance,SocketSlot};
        use std::sync::{Arc,atomic::AtomicBool};
        crate::subagents::enter_task(TaskContext{cancel:Arc::new(AtomicBool::new(false)),deadline:None,
            sockets:SocketSlot::default(),owner:"child-fixture".into(),provenance:Provenance::Child});
        let spec=super::configure_spec(wa_operation::Spec::command("fixture",vec![]),"",1,"".into(),false,false);
        crate::subagents::leave_task();
        assert!(spec.env.contains(&("WASM_AGENT_IN_TURN".into(),"1".into())));
        assert!(spec.env.contains(&("WASM_AGENT_PROVENANCE".into(),"child".into())));
        assert_eq!(spec.owner,"child-fixture");
    }
    // What the reader gets is the measurement, in the order the operation spends it.
    #[test]
    fn the_note_reports_the_measured_phases() {
        let state = json!({
            "elapsed_ms": 61005,
            "timing": {"setup_ms": 8712, "spawn_ms": 10, "execution_ms": 51182, "drain_cleanup_ms": 1000}
        });
        assert_eq!(
            deadline_note(60, &state),
            "the command did not finish within 60s; its operation was terminated after 61005ms \
             (setup 8712ms, spawn 10ms, executing 51182ms, cleanup 1000ms)."
        );
    }

    // The sentence this replaced was printed for *every* deadline and read onward as a
    // diagnosis. It must not come back in any form.
    #[test]
    fn the_note_never_names_a_cause() {
        let state = json!({"elapsed_ms": 300006, "timing": {"execution_ms": 299000}});
        let note = deadline_note(300, &state);
        assert!(!note.contains("busy session"), "{note}");
        assert!(!note.contains("independent route"), "{note}");
        assert!(note.contains("executing 299000ms"), "{note}");
    }

    // An operation killed before a phase was measured says what is known rather than inventing.
    #[test]
    fn a_missing_breakdown_is_stated_not_invented() {
        let state = json!({"elapsed_ms": 5000});
        assert_eq!(
            deadline_note(4, &state),
            "the command did not finish within 4s; its operation was terminated after 5000ms \
             (no phase breakdown was recorded)."
        );
    }
}

#[cfg(test)]
mod command_launch_tests {
    use super::{
        command_launch, command_line_overflow, stage_command_in, STAGED_COMMAND_LIMIT,
        WINDOWS_INLINE_COMMAND_BUDGET,
    };

    #[test]
    fn short_commands_stay_inline() {
        let launch = command_launch("bash", "-c", "echo short").expect("short command launches");
        assert!(launch.staged.is_none());
        assert_eq!(launch.args, vec!["-c".to_string(), "echo short".to_string()]);
    }

    // The measured trap: Git-Bash cuts a `-c` string at 8192 bytes, so a 10 KB command
    // must run from a staged file instead of being put on the command line.
    #[test]
    fn a_multi_kb_command_is_staged_instead_of_refused() {
        let command = format!("#{}\necho REACHED\n", "x".repeat(10_000));
        assert_eq!(command_line_overflow("bash", "-c", &command), cfg!(windows));
        let launch = command_launch("bash", "-c", &command).expect("a 10 KB command must launch");
        if cfg!(windows) {
            let path = launch.staged.as_ref().expect("over-long command must be staged");
            assert_eq!(std::fs::read_to_string(path).unwrap(), command, "staged bytes are exact");
            assert_eq!(launch.args, vec![path.to_string_lossy().into_owned()], "bash <file>");
            let _ = std::fs::remove_file(path);
        } else {
            assert!(launch.staged.is_none(), "no command-line limit to work around");
        }
    }

    #[test]
    fn staged_bytes_are_exact_and_private() {
        let dir = std::env::temp_dir().join(format!("wa-command-stage-{}", std::process::id()));
        let body = "echo 'aspas \" e $VAR'\r\necho segunda linha\n";
        let path = stage_command_in(&dir, body).expect("stage");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), body);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&dir);
    }

    #[test]
    fn absurd_scripts_are_still_refused_by_name() {
        let command = "x".repeat(STAGED_COMMAND_LIMIT + 1);
        let error = match command_launch("bash", "-c", &command) {
            Ok(_) => panic!("a 1 MiB command must refuse"),
            Err(error) => error,
        };
        assert!(error.contains("shell_command_too_long"), "{error}");
    }

    // `` and `"` escape to two units, so a quote-heavy command reaches the bound sooner.
    #[test]
    fn counts_quoting_overhead_towards_the_bound() {
        let command = "\"".repeat(WINDOWS_INLINE_COMMAND_BUDGET / 2 + 10);
        assert_eq!(command_line_overflow("bash", "-c", &command), cfg!(windows));
    }
}

/// No silent deadline. A caller that gives no `timeout_seconds` gets a default chosen by what the command
/// IS, and the receipt says so; an explicit timeout is used as given. Measured on wasm_the_first
/// (2026-11-10): a supervised build died at the 300 s command default because its caller passed nothing -
/// the deadline was real, applied, and never mentioned.
#[cfg(test)]
mod operation_deadline_tests {
    use super::{default_operation_timeout_seconds, operation_kind};
    use serde_json::json;

    #[test]
    fn the_default_follows_the_kind_of_work() {
        assert_eq!(default_operation_timeout_seconds("build"), 5400);
        assert_eq!(default_operation_timeout_seconds("test"), 3600);
        assert_eq!(default_operation_timeout_seconds("deploy"), 3600);
        assert_eq!(default_operation_timeout_seconds("command"), 300);
        assert_eq!(default_operation_timeout_seconds("something-else"), 300);
    }

    #[test]
    fn a_command_is_classified_from_what_it_runs() {
        assert_eq!(operation_kind(&json!({}), "cargo build --release --offline").unwrap(), "build");
        assert_eq!(operation_kind(&json!({}), "bash scripts/build-window.sh").unwrap(), "build");
        assert_eq!(operation_kind(&json!({}), "bash scripts/fast.sh").unwrap(), "test");
        assert_eq!(operation_kind(&json!({}), "cargo test --offline -p wa-host").unwrap(), "test");
        assert_eq!(operation_kind(&json!({}), "bash scripts/deploy.sh").unwrap(), "deploy");
        assert_eq!(operation_kind(&json!({}), "git status").unwrap(), "command");
        assert_eq!(operation_kind(&json!({}), "rm -rf /tmp/x").unwrap(), "command");
    }

    #[test]
    fn an_explicit_kind_wins_and_a_wrong_one_is_refused() {
        assert_eq!(operation_kind(&json!({"kind": "build"}), "git status").unwrap(), "build");
        let error = operation_kind(&json!({"kind": "everything"}), "git status").unwrap_err();
        assert!(error.starts_with("operation_kind_unknown:everything"), "{error}");
        assert!(error.contains("expected one of command, build, test, deploy"), "{error}");
    }
}

/// The vault slot's retry rule, without a vault: what a launch does the second time an open failed.
#[cfg(test)]
mod vault_cache_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn a_failed_open_is_tried_again_on_the_next_call() {
        let slot: std::sync::Mutex<Option<u8>> = std::sync::Mutex::new(None);
        let attempts = AtomicUsize::new(0);
        // The first launch: the vault does not open (the keystore is not there yet).
        let open_failing = || { attempts.fetch_add(1, Ordering::SeqCst); None };
        assert!(!ensure_cached(&slot, open_failing), "the launch is told there is no vault");
        assert_eq!(attempts.load(Ordering::SeqCst), 1);
        // The second launch: it opens now. The failure was NOT remembered, which is the whole fix.
        let open_working = || { attempts.fetch_add(1, Ordering::SeqCst); Some(7u8) };
        assert!(ensure_cached(&slot, open_working), "the next launch opens the vault, no restart needed");
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
        assert_eq!(*slot.lock().unwrap(), Some(7));
    }

    #[test]
    fn a_vault_that_opened_is_not_reopened_on_every_launch() {
        let slot: std::sync::Mutex<Option<u8>> = std::sync::Mutex::new(Some(1));
        let attempts = AtomicUsize::new(0);
        let open = || { attempts.fetch_add(1, Ordering::SeqCst); Some(2u8) };
        assert!(ensure_cached(&slot, open));
        assert!(ensure_cached(&slot, open));
        assert_eq!(attempts.load(Ordering::SeqCst), 0, "an open vault is reused, never reopened");
        assert_eq!(*slot.lock().unwrap(), Some(1), "and the second opener never runs");
    }

    // The launch path itself, not a helper beside it: `vault_value` opens the slot through
    // `ensure_cached`, so a failure is retried on the next launch and an open vault is reused.
    #[test]
    fn the_launch_path_opens_the_vault_through_the_one_retry_rule() {
        let slot: std::sync::Mutex<Option<u8>> = std::sync::Mutex::new(None);
        let attempts = AtomicUsize::new(0);
        let missing = super::vault_value_with(&slot,
            || { attempts.fetch_add(1, Ordering::SeqCst); None }, |value: &u8| Ok(value.to_string()));
        assert!(missing.unwrap_err().starts_with("vault_unavailable"), "a launch with no vault says so");
        assert_eq!(attempts.load(Ordering::SeqCst), 1);
        let opened = super::vault_value_with(&slot,
            || { attempts.fetch_add(1, Ordering::SeqCst); Some(7u8) }, |value: &u8| Ok(format!("v{value}")));
        assert_eq!(opened.unwrap(), "v7", "the next launch opens the vault: no restart needed");
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
        let reused = super::vault_value_with(&slot,
            || { attempts.fetch_add(1, Ordering::SeqCst); Some(9u8) }, |value: &u8| Ok(value.to_string()));
        assert_eq!(reused.unwrap(), "7", "an open vault is reused, never reopened");
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
    }
}

/// The approval a connector that names a vault entry carries (docs/VAULT.md): the digest covers the
/// program, the arguments, every script file the connector runs, and the environment names it asks for.
/// These are the adversarial directions the review named: a script edited after the approval, changed
/// arguments, a launch running a script the approval does not name, and a missing approval.
#[cfg(test)]
mod vault_approval_tests {
    use super::{approval_problem, approval_text, is_absolute_path, is_script_path, looks_like_path,
                platform_root, request_server_problem, seal_request, sha256_hex, APPROVAL_FORM};
    use serde_json::{json, Value};

    fn scratch(name: &str, body: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("wa-vault-approval-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        let path = dir.join(name);
        std::fs::write(&path, body).expect("scratch script");
        path
    }

    /// A NATIVE binary copied under a chosen name, for fixtures that must pass the allow-list: a shell
    /// script is refused as a program now, so a fixture program has to be a real ELF/Mach-O/PE file.
    fn native_copy(name: &str) -> std::path::PathBuf {
        let source = ["/usr/bin/env", "/bin/env", "/usr/bin/true", "/bin/true"]
            .into_iter()
            .find(|candidate| {
                super::file_magic(candidate).as_deref() == Some("elf")
                    || super::file_magic(candidate).as_deref() == Some("macho")
            })
            .expect("a native binary to copy for the fixtures");
        let dir = std::env::temp_dir().join(format!("wa-vault-approval-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        let path = dir.join(name);
        std::fs::copy(source, &path).expect("a native fixture");
        path
    }

    /// An approval that ALSO carries the operator's --native voucher for a program outside the two
    /// families: the one shape in which a native binary runs a vault connector (round 8).
    fn approval_native(program: &std::path::Path, files: &[&std::path::Path], vault: &[&str]) -> Value {
        let mut document = approval(&program.to_string_lossy(), "", &[], &[], files, vault);
        let real = super::real_path(&program.to_string_lossy());
        let sha = sha256_hex(&std::fs::read(program).expect("the vouched binary"));
        // The console SORTS the file list before hashing it (lua/core/mcp.lua, M.vault_manifest:
        // `table.sort(files, ...)`), and approval_problem sorts it too - so a helper that handed the list
        // in the order it was written built a digest the kernel would never reproduce. One file hid it.
        let mut listed: Vec<(String, String)> = files.iter().map(|path| (path.to_string_lossy().to_string(),
            sha256_hex(&std::fs::read(path).expect("a covered file")))).collect();
        listed.sort_by(|left, right| left.0.cmp(&right.0));
        document["files"] = json!(listed.iter().map(|(path, _)| path.clone()).collect::<Vec<_>>());
        let text = approval_text(&document["program"].as_str().unwrap_or_default().to_string(), "", &[],
            &[], &listed,
            &vault.iter().map(|entry| entry.to_string()).collect::<Vec<_>>(),
            Some((real.as_str(), sha.as_str())));
        document["sha256"] = json!(sha256_hex(text.as_bytes()));
        document["native"] = json!({"path": real, "sha256": sha});
        document
    }

    /// A NATIVE binary in this user's own directory, under a name the allow-list accepts (round 8: a
    /// program is judged by its REALPATH's basename and by its leading bytes, so a `#!/bin/sh` fixture
    /// called `node` is exactly what the allow-list refuses). Copied from the platform's own, and given a
    /// subdirectory so two tests running at once cannot collide on one file.
    fn scratch_native(name: &str) -> std::path::PathBuf {
        let source = ["/usr/bin/env", "/bin/env", "/usr/bin/true", "/bin/true"].iter()
            .find(|candidate| std::fs::metadata(candidate).is_ok())
            .copied().expect("a native binary on this host to copy");
        // One directory PER CALL: these tests run in parallel, and a copy removed by the test that
        // finished first was a copy the next one still needed (`program_not_native` on a real ELF).
        use std::sync::atomic::{AtomicU64, Ordering};
        static SERIAL: AtomicU64 = AtomicU64::new(0);
        let serial = SERIAL.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir()
            .join(format!("wa-vault-approval-{}/native-{serial}", std::process::id())).join(name);
        std::fs::create_dir_all(path.parent().expect("a parent")).expect("scratch dir");
        std::fs::copy(source, &path).expect("a native copy");
        path
    }

    fn spec(program: &str, args: &[String]) -> wa_operation::Spec {
        wa_operation::Spec::command(program.to_string(), args.to_vec())
    }

    /// An approval as the console records one (lua/core/mcp.lua, M.vault_manifest): the form, the digest
    /// over the bytes on disk, and the fields that digest covers.
    fn approval(program: &str, cwd: &str, env: &[(&str, &str)], args: &[String],
                files: &[&std::path::Path], vault: &[&str]) -> Value {
        let list: Vec<(String, String)> = files.iter().map(|path| {
            let body = std::fs::read(path).expect("a file the approval covers");
            (path.to_string_lossy().to_string(), sha256_hex(&body))
        }).collect();
        let env: Vec<(String, String)> = env.iter().map(|(name, reference)| (name.to_string(), reference.to_string())).collect();
        let vault: Vec<String> = vault.iter().map(|entry| entry.to_string()).collect();
        let digest = sha256_hex(approval_text(program, cwd, &env, args, &list, &vault, None).as_bytes());
        json!({"form": APPROVAL_FORM, "sha256": digest, "program": program, "cwd": cwd,
            "env": env.iter().map(|(name, reference)| json!({"name": name, "ref": reference})).collect::<Vec<_>>(),
            "args": args,
            "files": files.iter().map(|path| path.to_string_lossy().to_string()).collect::<Vec<_>>(),
            "vault": vault})
    }

    /// The request file a launch reads: the shape lua/core/mcp.lua writes and mcp-client.mjs spawns from.
    fn request(program: &str, args: &[&str], cwd: Option<&str>) -> Vec<u8> {
        let mut server = json!({"transport": "stdio", "program": program, "args": args,
            "env": {"TOKEN": "TOKEN"}});
        if let Some(cwd) = cwd { server["cwd"] = json!(cwd); }
        serde_json::to_vec(&json!({"action": "call", "server": server, "tool": "echo"}))
            .expect("a request file")
    }

    // The ONE canonical text: a newline, a space or a tab inside a field cannot forge a line, and the
    // same fixture hashes to the same digest on both sides (see the Lua pin in
    // scripts/test-mcp-vault-approval.lua).
    #[test]
    fn the_canonical_text_escapes_fields_and_matches_the_lua_side() {
        let env: Vec<(String, String)> = vec![("MAIL_USER".into(), "MAIL_USER".into()),
            ("LANG".into(), "LC_ALL".into())];
        let text = approval_text(
            "/usr/bin/node",
            "/home/agent/work tree",
            &env,
            &["/home/agent/scripts/fixture.mjs".into(), "--token".into(), "a b".into()],
            &[("/home/agent/scripts/fixture.mjs".into(), "aa".repeat(32)),
              ("/home/agent/scripts/lib/other.mjs".into(), "bb".repeat(32))],
            &["FIXTURE_TOKEN".into(), "SECOND_ONE".into()],
            None,
        );
        assert!(text.starts_with("mcp-vault-approval/v4\nprogram /usr/bin/node\ncwd /home/agent/work%20tree\n"), "{text}");
        assert!(text.contains("\nenv LANG=LC_ALL\nenv MAIL_USER=MAIL_USER\narg "), "the plain environment is sorted by name: {text}");
        assert!(text.contains("\narg a%20b\n"), "a space is escaped, not a separator: {text}");
        assert_eq!(sha256_hex(text.as_bytes()),
            "0d7f15fd975c32c4d5875437dfc193931fbc01972a83f55d1b01c736c6e8ee0b",
            "the digest the Lua side pins for the same fixture");
    }

    #[test]
    fn an_approved_launch_is_accepted_and_an_edited_script_is_not() {
        let script = scratch("plain.mjs", "export const ok = 1;\n");
        let client = scratch("client.mjs", "import './plain.mjs';\n");
        let args = vec![client.to_string_lossy().to_string(), "--request-file".into(), "/tmp/request.json".into()];
        let ok = approval("/usr/bin/node", "", &[], &args, &[&client, &script], &["TOKEN"]);
        assert!(approval_problem(&ok, &spec("/usr/bin/node", &args)).is_ok(),
            "what the operator approved launches: {:?}", approval_problem(&ok, &spec("/usr/bin/node", &args)));

        // The attack the review measured: the script of an approved connector is rewritten afterwards.
        std::fs::write(&script, "export const ok = 2; // replaced after the approval\n").expect("rewrite");
        let refused = approval_problem(&ok, &spec("/usr/bin/node", &args)).unwrap_err();
        assert!(refused.starts_with("vault_approval_mismatch:"), "{refused}");
        assert!(refused.contains("/mcp <id> probe"), "the refusal says how to approve it again: {refused}");

        // Approving the OLD bytes again still does not help now: the digest is over what is on disk.
        std::fs::write(&script, "export const ok = 1;\n").expect("restore");
        assert!(approval_problem(&ok, &spec("/usr/bin/node", &args)).is_ok(), "the approved bytes are back");
        // ARGUMENTS are in the digest too: an approval minted for one command line does not cover
        // another.
        let mut other = ok.clone();
        let mut moved: Vec<String> = args.clone();
        moved.push("--extra".into());
        other["args"] = json!(moved);
        let refused = approval_problem(&other, &spec("/usr/bin/node", &args)).unwrap_err();
        assert!(refused.starts_with("vault_approval_mismatch:"), "{refused}");
        // THE CWD and the PLAIN ENVIRONMENT are in it as well (this round): a connector moved to another
        // directory, or one that now asks for another variable, is not the launch that was approved.
        let mut moved_cwd = ok.clone();
        moved_cwd["cwd"] = json!("/tmp");
        assert!(approval_problem(&moved_cwd, &spec("/usr/bin/node", &args)).unwrap_err()
            .starts_with("vault_approval_mismatch:"));
        let mut moved_env = ok.clone();
        moved_env["env"] = json!([{"name": "PROXY", "ref": "PROXY"}]);
        assert!(approval_problem(&moved_env, &spec("/usr/bin/node", &args)).unwrap_err()
            .starts_with("vault_approval_mismatch:"));
        let _ = std::fs::remove_file(&script);
        let _ = std::fs::remove_file(&client);
    }

    #[test]
    fn a_launch_running_a_script_the_approval_does_not_name_is_refused() {
        let client = scratch("uncovered-client.mjs", "export const c = 1;\n");
        let smuggled = scratch("smuggled.sh", "echo value\n");
        let approved_args = vec![client.to_string_lossy().to_string()];
        let ok = approval("/usr/bin/node", "", &[], &approved_args, &[&client], &[]);
        let running = spec("/usr/bin/node",
            &[client.to_string_lossy().to_string(), smuggled.to_string_lossy().to_string()]);
        let refused = approval_problem(&ok, &running).unwrap_err();
        assert!(refused.starts_with("vault_approval_script_not_covered:"), "{refused}");
        assert!(refused.contains("smuggled.sh"), "{refused}");
        let _ = std::fs::remove_file(&client);
        let _ = std::fs::remove_file(&smuggled);
    }

    #[test]
    fn a_missing_approval_or_a_missing_script_reads_nothing() {
        let running = spec("/usr/bin/node", &["/tmp/client.mjs".to_string()]);
        for empty in [Value::Null, json!({}), json!({"sha256": "  "})] {
            let refused = approval_problem(&empty, &running).unwrap_err();
            assert!(refused.starts_with("vault_approval_required:"), "{refused}");
        }
        let vanished = json!({"form": APPROVAL_FORM, "sha256": "00".repeat(32), "program": "/usr/bin/node",
            "cwd": "", "env": [], "args": [], "files": ["/nonexistent/wasm-agent/connector.mjs"], "vault": []});
        let refused = approval_problem(&vanished, &spec("/usr/bin/node", &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_unreadable:/nonexistent/wasm-agent/connector.mjs"), "{refused}");
    }

    // A row approved before this round covers v1's fields only: it cannot be compared against v2's
    // digest, so it is refused by name and the operator approves again.
    #[test]
    fn an_approval_that_predates_the_form_is_refused() {
        let mut old = json!({"sha256": "ab".repeat(32), "program": "/usr/bin/node", "args": [],
            "files": [], "vault": []});
        let refused = approval_problem(&old, &spec("/usr/bin/node", &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_digest_form:"), "{refused}");
        assert!(refused.contains("/mcp <id> probe"), "{refused}");
        old["form"] = json!("mcp-vault-approval/v1");
        assert!(approval_problem(&old, &spec("/usr/bin/node", &[])).unwrap_err()
            .starts_with("vault_approval_digest_form:"));
    }

    // A program the platform does not own is the connector's own code (this round's second hole): it
    // must be a file the digest names, or the launch reads no value.
    #[test]
    fn a_program_the_platform_does_not_own_must_be_in_the_digest() {
        // Round 8 judges the program BEFORE its coverage: a file that is not node or a POSIX shell is
        // refused by the allow-list, whatever the digest says about it. A user-owned node is the shape
        // that reaches the coverage rule - allowed as a program, and still a file this launch runs.
        let binary = scratch_native("node");
        let program = binary.to_string_lossy().to_string();
        let unlisted = approval("/usr/bin/node", "", &[], &[], &[], &["TOKEN"]);
        let mut named = unlisted.clone();
        named["program"] = json!(program);
        let refused = approval_problem(&named, &spec(&program, &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_covered:"), "{refused}");
        // Named by the digest, the same launch is accepted.
        let covered = approval(&program, "", &[], &[], &[&binary], &["TOKEN"]);
        assert!(approval_problem(&covered, &spec(&program, &[])).is_ok(),
            "{:?}", approval_problem(&covered, &spec(&program, &[])));
        // A shell script OUTSIDE both families is refused earlier, by the allow-list: it is the same
        // launch as a python or a copy of node under another name.
        let script = scratch("home-conn", "#!/bin/sh\necho value\n");
        let scripted = script.to_string_lossy().to_string();
        let mut smuggled = unlisted.clone();
        smuggled["program"] = json!(scripted);
        let refused = approval_problem(&smuggled, &spec(&scripted, &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        let _ = std::fs::remove_file(&binary);
        let _ = std::fs::remove_file(&script);
    }

    #[test]
    fn a_relative_path_or_a_package_runner_cannot_be_approved() {
        let bare = approval("node", "", &[], &[], &[], &["TOKEN"]);
        assert!(approval_problem(&bare, &spec("/usr/bin/node", &[])).unwrap_err()
            .starts_with("vault_approval_program_not_absolute:node:"), "a name is resolved through PATH");
        let runner = approval("npx", "", &[], &[], &[], &["TOKEN"]);
        let refused = approval_problem(&runner, &spec("/usr/bin/node", &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_package_runner:npx:"), "{refused}");
        let relative = approval("/usr/bin/node", "", &[], &["conn.mjs".into()], &[], &["TOKEN"]);
        let refused = approval_problem(&relative, &spec("/usr/bin/node", &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_path_not_absolute:conn.mjs:"), "{refused}");
        // The shape helpers are the same rules the console applies (M.vault_manifest).
        assert!(!looks_like_path("--token") && !looks_like_path("https://example.com/mcp"));
        assert!(looks_like_path("conn.mjs") && looks_like_path("./lib/x.mjs") && looks_like_path("/a/b"));
        assert!(is_absolute_path("/usr/bin/node") && !is_absolute_path("conn.mjs"));
        assert!(platform_root("/usr/bin/node") && platform_root("/nix/store/x/bin/node"));
        assert!(!platform_root("/home/agent/bin/conn"), "the agent's own directory is not the platform's");
    }

    #[test]
    fn only_absolute_script_paths_are_covered_by_the_launch_cross_check() {
        assert!(is_script_path("/home/agent/scripts/mcp-client.mjs"));
        assert!(is_script_path("C:\\Users\\agent\\scripts\\connector.py"));
        assert!(!is_script_path("mcp-client.mjs"), "a bare name is resolved by PATH, not by us");
        assert!(!is_script_path("/tmp/request.json"), "a request file is not a script");
        assert!(!is_script_path("--request-file"));
        assert!(!is_script_path("/usr/bin/node"), "the platform binary is not the connector's script");
    }

    // This round's first hole: the child spawns server.program/args/cwd from the request file, so THAT
    // command must be the one the operator approved.
    #[test]
    fn the_request_the_child_reads_must_name_the_approved_command() {
        let client = scratch("request-client.mjs", "export const c = 1;\n");
        let client_path = client.to_string_lossy().to_string();
        let approved_args = vec![client_path.clone()];
        let approved = approval("/usr/bin/node", "", &[], &approved_args, &[&client], &["TOKEN"]);
        let good = request("/usr/bin/node", &[&client_path], None);
        assert!(request_server_problem(&good, &approved).is_ok(),
            "{:?}", request_server_problem(&good, &approved));

        // The attack: a background loop rewrites server.program between the console's write and the
        // child's read.
        let smuggled = request("/bin/sh", &["-c", "echo $TOKEN"], None);
        let refused = request_server_problem(&smuggled, &approved).unwrap_err();
        assert!(refused.starts_with("vault_request_program_mismatch:"), "{refused}");
        assert!(refused.contains("/bin/sh"), "{refused}");
        // A command line, a directory or a transport the operator never approved.
        let extra = request("/usr/bin/node", &[&client_path, "--eval", "1"], None);
        assert!(request_server_problem(&extra, &approved).unwrap_err()
            .starts_with("vault_request_arguments_mismatch:"));
        let mut rewired = request("/usr/bin/node", &[&client_path], None);
        let mut document: Value = serde_json::from_slice(&rewired).expect("a request");
        document["server"]["env"] = json!({"TOKEN": "TOKEN", "EXTRA": "PATH"});
        rewired = serde_json::to_vec(&document).expect("a request");
        assert!(request_server_problem(&rewired, &approved).unwrap_err()
            .starts_with("vault_request_environment_mismatch:"));
        let moved = request("/usr/bin/node", &[&client_path], Some("/tmp"));
        assert!(request_server_problem(&moved, &approved).unwrap_err().starts_with("vault_request_cwd_mismatch:"));
        let http = serde_json::to_vec(&json!({"server": {"transport": "http", "url": "https://example.com/mcp"}}))
            .expect("a request");
        assert!(request_server_problem(&http, &approved).unwrap_err()
            .starts_with("vault_request_transport_not_checked:"));
        let garbage = b"not a request".to_vec();
        assert!(request_server_problem(&garbage, &approved).unwrap_err().starts_with("vault_request_unreadable:"));
        // A relative script, and a program outside the platform's roots the approval does not name.
        let mut relative = approved.clone();
        relative["args"] = json!(["conn.mjs"]);
        assert!(request_server_problem(&request("/usr/bin/node", &["conn.mjs"], None), &relative)
            .unwrap_err().starts_with("vault_request_path_not_absolute:"));
        // A program outside the platform's roots the approval does not name. It is a native node, so
        // the refusal is the COVERAGE one: a file in neither family is refused earlier, by the allow-list
        // (round 8), which is asserted straight after.
        let binary = scratch_native("node");
        let program = binary.to_string_lossy().to_string();
        let mut outside = approved.clone();
        outside["program"] = json!(program);
        outside["args"] = json!([]);
        assert!(request_server_problem(&request(&program, &[], None), &outside).unwrap_err()
            .starts_with("vault_request_program_not_covered:"));
        let script = scratch("request-conn", "#!/bin/sh\necho value\n");
        let scripted = script.to_string_lossy().to_string();
        let mut family = approved.clone();
        family["program"] = json!(scripted);
        family["args"] = json!([]);
        // The request-side check answers with the approval's own words for a PROGRAM (the console and the
        // kernel share one judgement, program_shape_problem), and with `vault_request_` for the arguments
        // it re-resolves against this request's own words.
        assert!(request_server_problem(&request(&scripted, &[], None), &family).unwrap_err()
            .starts_with("vault_approval_program_not_allowed:"));
        let _ = std::fs::remove_file(&client);
        let _ = std::fs::remove_file(&binary);
        let _ = std::fs::remove_file(&script);
    }

    // The seal half: the child is told the sha256 of the exact bytes the kernel checked, so a rewrite
    // after that check is refused in the child (scripts/test-mcp-request-seal.mjs proves the child side).
    #[test]
    fn the_request_seal_is_the_sha256_of_the_bytes_the_kernel_read() {
        let dir = std::env::temp_dir().join(format!("wa-request-seal-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        let path = dir.join("request.json");
        let bytes = request("/usr/bin/node", &["/abs/conn.mjs"], None);
        std::fs::write(&path, &bytes).expect("the request");
        let path_text = path.to_string_lossy().to_string();
        let mut launch = spec("/usr/bin/node", &["--request-file".into(), path_text.clone()]);
        let approval = json!({"form": APPROVAL_FORM});
        assert!(seal_request(&mut launch, &approval, false).is_ok(),
            "a plain launch is sealed without an approval check");
        let sealed = launch.env.iter().find(|(name, _)| name == "WA_MCP_REQUEST_SHA256")
            .map(|(_, value)| value.clone());
        assert_eq!(sealed, Some(sha256_hex(&bytes)), "the child is given the bytes the kernel read");
        assert_eq!(launch.env.iter().find(|(name, _)| name == "WA_MCP_REQUEST_FILE").map(|(_, value)| value.clone()),
            Some(path_text.clone()));
        // A rewrite after the seal is exactly what the child refuses: what is on disk no longer hashes
        // to what was checked.
        std::fs::write(&path, request("/bin/sh", &["-c", "echo $TOKEN"], None)).expect("rewrite");
        assert_ne!(sealed, Some(sha256_hex(&std::fs::read(&path).expect("the rewritten request"))),
            "the sealed digest is the bytes the kernel checked, not what is on disk later");
        // A vault launch that names no request file has nothing to compare the approved command against.
        let mut bare = spec("/usr/bin/node", &[]);
        assert!(seal_request(&mut bare, &approval, true).unwrap_err().starts_with("vault_request_unnamed:"));
        assert!(seal_request(&mut bare, &approval, false).is_ok(), "a plain launch needs no request file");
        let _ = std::fs::remove_file(&path);
    }

    // ---- round 6: the interpreter, the arguments, the ownership of a platform root, the recheck ----
    //
    // Each of these fails on 6596aecc. They are the four shapes the review named, from the approval's own
    // data, so they hold for a launch the console never touched.

    /// Findings 1 and 5: the process the vault values are put in is the interpreter the launch SPAWNS,
    /// which is not always the definition's program, and "/usr/bin is the platform's" is a claim about
    /// OWNERSHIP - a path prefix alone called /usr/local/bin the platform's on a machine where the user
    /// owns it.
    #[test]
    fn the_interpreter_the_launch_spawns_is_the_platforms_own_or_in_the_digest() {
        // Round 8: this fixture is a REAL native node, because the allow-list judges the spawned
        // interpreter by what the file IS - a shell script called `node` is refused by it, one step
        // before the coverage rule this test is about.
        let owned = scratch_native("node");
        let ours = super::real_path(&owned.to_string_lossy());
        // A file this user owns is never the platform's, and a platform prefix cannot make it so.
        assert!(!super::owned_by_root(&ours), "a file this user owns is not root-owned: {ours}");
        assert!(!super::platform_owned(&ours), "and a path the platform does not own is not platform_owned");
        // The real thing is: a root-owned, not group/other-writable system program and its directories.
        assert!(super::owned_by_root("/usr/bin"), "/usr/bin is root-owned and not writable by us");
        assert!(super::platform_owned("/usr/bin/env"), "/usr/bin/env is the platform's own");
        assert!(!super::platform_owned("/usr/local/bin/wasm-agent-nothing-here"),
            "a path that is not there is not the platform's");
        assert!(super::PLATFORM_ROOTS.contains(&"/System/"), "the Lua and Rust lists agree (/System/)");

        // The definition names the platform's node; the launch is told to spawn a file this user owns,
        // which nobody hashed - the WA_NODE shape, and <data>/node after it.
        let approved = approval("/usr/bin/node", "", &[], &[], &[], &["TOKEN"]);
        let refused = approval_problem(&approved, &spec(&ours, &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_interpreter_not_covered:"), "{refused}");
        assert!(refused.contains(&ours), "the refusal names the interpreter: {refused}");
        // Covered by the digest, the same launch reads the value.
        let covered = approval("/usr/bin/node", "", &[], &[], &[&owned], &["TOKEN"]);
        assert!(approval_problem(&covered, &spec(&ours, &[])).is_ok(),
            "{:?}", approval_problem(&covered, &spec(&ours, &[])));
        let _ = std::fs::remove_file(&owned);
    }

    /// Round 8: the spawned interpreter is judged by the same ALLOW-LIST as the connector's own program,
    /// and that arm had no test on either side - the test above asserts interpreter_not_covered, which
    /// fires one step LATER. On a host where "which node" is a mise/asdf/nvm shim the realpath is not
    /// node (measured here: /home/victor/.local/share/mise/shims/node -> /usr/bin/mise), so this arm is
    /// the first thing such a host hits.
    #[test]
    fn the_interpreter_the_launch_spawns_is_held_to_the_allow_list() {
        // A native binary whose REALPATH is an interpreter: it is native, it is in the digest, and it is
        // still refused, because what it IS (python3) is not one of the two families.
        let interpreter = native_copy("python3");
        let approved = approval("/usr/bin/node", "", &[], &[], &[&interpreter], &["TOKEN"]);
        let refused = approval_problem(&approved, &spec(&interpreter.to_string_lossy(), &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        // And a copy NAMED node that is only a shell script: the name is not the program, so it is
        // refused one branch later (not_native) than a name outside the allow-list.
        // Round 9: NOT `fake-node` in the shared directory. The round-6 test beside this one writes a FILE
        // of that name through `scratch` (a shell script called node), and a directory and a file cannot
        // share the path: whichever ran second failed with `AlreadyExists`, one suite run in three. The
        // directory is its own subtree, so both tests keep their fixture.
        let fake_dir = std::env::temp_dir()
            .join(format!("wa-vault-approval-{}/fake-node-tree", std::process::id()));
        std::fs::create_dir_all(&fake_dir).expect("scratch dir");
        let fake = fake_dir.join("node");
        std::fs::write(&fake, "#!/bin/sh\nexit 0\n").expect("a shell script called node");
        let vouched = approval("/usr/bin/node", "", &[], &[], &[&fake], &["TOKEN"]);
        let refused = approval_problem(&vouched, &spec(&fake.to_string_lossy(), &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_native:"), "{refused}");
    }

    /// Finding 5: Lua and Rust keep lists of refused names, and they drifted - the Rust list matched
    /// "Rscript" only by accident while Lua lowercased first. ONE table (fixtures/mcp-refused-names.json)
    /// is the source of both, and both compare case-insensitively.
    #[test]
    fn the_refused_name_lists_are_the_shared_table_and_case_insensitive() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/mcp-refused-names.json");
        let table: Value = serde_json::from_slice(&std::fs::read(&path).expect("the shared table"))
            .expect("the shared table is JSON");
        let listed = |key: &str| -> Vec<String> {
            table[key].as_array().expect(key).iter()
                .map(|entry| entry.as_str().expect("a name").to_string()).collect()
        };
        let mut rust_interpreters: Vec<String> =
            super::REFUSED_INTERPRETERS.iter().map(|name| name.to_string()).collect();
        let mut rust_wrappers: Vec<String> =
            super::REFUSED_WRAPPERS.iter().map(|name| name.to_string()).collect();
        let mut rust_allowed: Vec<String> =
            super::ALLOWED_PROGRAMS.iter().map(|name| name.to_string()).collect();
        let mut wanted_interpreters = listed("refused_interpreters");
        let mut wanted_wrappers = listed("refused_wrappers");
        let mut wanted_allowed = listed("allowed_programs");
        rust_interpreters.sort();
        wanted_interpreters.sort();
        rust_wrappers.sort();
        wanted_wrappers.sort();
        rust_allowed.sort();
        wanted_allowed.sort();
        assert_eq!(rust_interpreters, wanted_interpreters, "the interpreter list is the shared table");
        assert_eq!(rust_wrappers, wanted_wrappers, "the wrapper list is the shared table");
        assert_eq!(rust_allowed, wanted_allowed, "the allow-list is the shared table");
        // Case-insensitive on BOTH sides: "Rscript" (as macOS spells it) is the same name as "rscript".
        for spelling in ["Rscript", "RSCRIPT", "rscript"] {
            let found = super::refused_interpreter_or_wrapper(spelling)
                .unwrap_or_else(|| panic!("{spelling} is a refused interpreter"));
            assert_eq!(found.0, "interpreter", "{spelling}");
        }
        for spelling in ["Env", "TIMEOUT", "timeout"] {
            let found = super::refused_interpreter_or_wrapper(spelling)
                .unwrap_or_else(|| panic!("{spelling} is a refused wrapper"));
            assert_eq!(found.0, "wrapper", "{spelling}");
        }
        // A versioned name is the same interpreter, and the allowed families are not in either list.
        assert_eq!(super::refused_interpreter_or_wrapper("python3.11").map(|found| found.0), Some("interpreter"));
        assert!(super::refused_interpreter_or_wrapper("node").is_none());
        assert!(super::refused_interpreter_or_wrapper("bash").is_none());
    }

    /// Round 8: the allow-list, judged by REALPATH and by what the file IS, and the voucher that is the
    /// one way a native binary outside the two families runs a vault connector.
    #[test]
    fn an_interpreter_or_a_wrapper_is_refused_whatever_its_name_or_voucher() {
        // Every refused family, under a versioned name and with its own argument list: refused as a
        // PROGRAM, whether or not the operator recorded a --native voucher for it.
        for program in ["/usr/bin/python3.11", "/usr/bin/perl5.36", "/usr/bin/env", "/usr/bin/timeout",
                        "/usr/bin/nohup", "/usr/bin/xargs"] {
            let refused = super::program_refusal(program, None)
                .unwrap_or_else(|| panic!("{program} is refused"));
            assert!(refused.starts_with("vault_approval_program_not_allowed:")
                || refused.starts_with("vault_approval_program_wrapper:"), "{program}: {refused}");
            let vouched = super::program_refusal(program, Some(program));
            assert!(vouched.is_some(), "--native must not approve {program}");
        }
        // A native binary under another name is NOT allowed without a voucher (its basename is not one
        // of the two families), and IS allowed with one - and then the bytes are in the digest.
        let copy = scratch("native-copy", "#!/bin/sh
exit 0
");
        let copied = super::real_path(&copy.to_string_lossy());
        let refused = super::program_refusal(&copied, None).expect("a name outside the two families");
        assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        // The voucher covers a NATIVE executable only: this fixture is a script, so even vouched for it
        // is refused by name rather than approved on a name the operator trusted.
        let vouched = super::program_refusal(&copied, Some(copied.as_str())).expect("a script is not native");
        assert!(vouched.starts_with("vault_approval_program_native_not_executable:"), "{vouched}");
        // A script wearing an ALLOWED name is refused too: /bin/sh copied to ./node is not node.
        let fake = scratch("fake-node", "#!/bin/sh
exit 0
");
        let fake_path = super::real_path(&fake.to_string_lossy());
        let refused = super::program_refusal(&fake_path, None).unwrap_or_default();
        assert!(refused.starts_with("vault_approval_program_native_not_executable:")
            || refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        let _ = std::fs::remove_file(&copy);
        let _ = std::fs::remove_file(&fake);
    }

    /// Round 8, finding 4: the flag is compared BEFORE an '=', and a short cluster is split, so
    /// "--eval=code" and "-pe" are the inline code a whole-string comparison let through.
    #[test]
    fn an_inline_flag_is_matched_before_its_value_and_through_a_cluster() {
        let inline = |program: &str, value: &str| super::inline_flag(program, value);
        assert_eq!(inline("/usr/bin/node", "--eval=process.exit(0)").as_deref(), Some("--eval"));
        assert_eq!(inline("/usr/bin/node", "--print=1").as_deref(), Some("--print"));
        assert_eq!(inline("/usr/bin/node", "-pe").as_deref(), Some("-p (in -pe)"));
        assert_eq!(inline("/bin/sh", "-ec").as_deref(), Some("-c (in -ec)"));
        // A long option is never split: --print is one flag, not --p, --r, --i, --n, --t. The run of
        // letters after the dash is not a cluster of short flags.
        assert_eq!(inline("/usr/bin/python3", "--require").as_deref(), Some("--require"));
        assert_eq!(inline("/usr/bin/python3", "--require=x").as_deref(), Some("--require"));
        assert_eq!(inline("/usr/bin/python3", "--nosuchflag"), None);
        assert_eq!(inline("/usr/bin/node", "--mode"), None);
        assert_eq!(inline("/usr/bin/node", "/abs/script.mjs"), None);
    }

    /// Finding 2: program /usr/bin/node, args ["server"], cwd /home/u/conn runs ./server.js, and
    /// looks_like_path saw nothing because "server" has no slash and no extension.
    #[test]
    fn an_argument_is_resolved_from_the_connectors_own_directory() {
        let dir = std::env::temp_dir().join(format!("wa-vault-cwd-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        let script = dir.join("server.js");
        std::fs::write(&script, "export const run = 1;\n").expect("the script a bare word names");
        let cwd = dir.to_string_lossy().to_string();
        let bare = vec!["server".to_string()];
        // Named by the digest, the bare word launches.
        let named = approval("/usr/bin/node", &cwd, &[], &bare, &[&script], &["TOKEN"]);
        assert!(approval_problem(&named, &spec("/usr/bin/node", &bare)).is_ok(),
            "{:?}", approval_problem(&named, &spec("/usr/bin/node", &bare)));
        // Not named, it is a file this launch runs and the approval does not cover.
        let unnamed = approval("/usr/bin/node", &cwd, &[], &bare, &[], &["TOKEN"]);
        let refused = approval_problem(&unnamed, &spec("/usr/bin/node", &bare)).unwrap_err();
        assert!(refused.starts_with("vault_approval_argument_not_covered:"), "{refused}");
        assert!(refused.contains("server.js"), "the refusal names the resolved file: {refused}");
        // A file that is not there cannot be resolved, so the argument is refused by name: it can appear
        // between the approval and the launch.
        let absent = vec!["absent".to_string()];
        let unresolved = approval("/usr/bin/node", &cwd, &[], &absent, &[], &["TOKEN"]);
        let refused = approval_problem(&unresolved, &spec("/usr/bin/node", &absent)).unwrap_err();
        assert!(refused.starts_with("vault_approval_argument_unresolved:absent:"), "{refused}");
        // An inline string is code no digest of files can name.
        let inline = vec!["-e".to_string(), "console.log(process.env.TOKEN)".to_string()];
        let run = approval("/usr/bin/node", &cwd, &[], &inline, &[], &["TOKEN"]);
        let refused = approval_problem(&run, &spec("/usr/bin/node", &inline)).unwrap_err();
        assert!(refused.starts_with("vault_approval_inline_code:-e:"), "{refused}");
        // The value of an option is a value, not a file: --mode stdio stays approvable.
        let option_value = vec![script.to_string_lossy().to_string(), "--mode".to_string(), "stdio".to_string()];
        let ok = approval("/usr/bin/node", &cwd, &[], &option_value, &[&script], &["TOKEN"]);
        assert!(approval_problem(&ok, &spec("/usr/bin/node", &option_value)).is_ok(),
            "{:?}", approval_problem(&ok, &spec("/usr/bin/node", &option_value)));
        let _ = std::fs::remove_file(&script);
    }

    // ---- round 7: node's own order, the ambiguity, the interpreters the digest cannot follow ----

    /// Finding 1: the implied extensions were .mjs, .js, .cjs, /index.* - neither node's order nor even the
    /// extensions node implies. `node ./a` with only a.mjs beside it does not run (measured on node 26), so
    /// the digest named a file nothing runs; with a.mjs AND a.js it runs a.js, which the digest had not
    /// hashed. node's order is matched (exact, .js, .json, .node, then the directory), and a name more than
    /// one file answers to is refused rather than resolved by node's priority.
    #[test]
    fn a_name_is_resolved_in_nodes_own_order_and_an_ambiguous_one_is_refused() {
        let dir = std::env::temp_dir().join(format!("wa-vault-order-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        let cwd = dir.to_string_lossy().to_string();
        let server_js = dir.join("server.js");
        std::fs::write(&server_js, "export const run = 1;
").expect("server.js");
        let word = vec!["server".to_string()];
        // The one file that answers to the word is covered, and a launch naming it is accepted.
        let named = approval("/usr/bin/node", &cwd, &[], &word, &[&server_js], &["TOKEN"]);
        assert!(approval_problem(&named, &spec("/usr/bin/node", &word)).is_ok(),
            "{:?}", approval_problem(&named, &spec("/usr/bin/node", &word)));
        // A second file that answers to the SAME word makes it ambiguous: the launch is refused by name,
        // and the refusal names both files, because neither of them is "the" file the operator approved.
        let server_json = dir.join("server.json");
        std::fs::write(&server_json, "{}").expect("server.json");
        let refused = approval_problem(&named, &spec("/usr/bin/node", &word)).unwrap_err();
        assert!(refused.starts_with("vault_approval_argument_ambiguous:server:"), "{refused}");
        assert!(refused.contains("server.js") && refused.contains("server.json"), "{refused}");
        std::fs::remove_file(&server_json).expect("remove server.json");
        // .mjs is NOT implied: with only alone.mjs there, node runs nothing, so the word resolves to
        // nothing either - the round-6 answer named alone.mjs and handed it the value.
        let alone = dir.join("alone");
        std::fs::create_dir_all(&alone).expect("scratch dir");
        std::fs::write(alone.join("alone.mjs"), "export const run = 3;
").expect("alone.mjs");
        let alone_cwd = alone.to_string_lossy().to_string();
        let word_alone = vec!["alone".to_string()];
        let unresolved = approval("/usr/bin/node", &alone_cwd, &[], &word_alone, &[], &["TOKEN"]);
        let refused = approval_problem(&unresolved, &spec("/usr/bin/node", &word_alone)).unwrap_err();
        assert!(refused.starts_with("vault_approval_argument_unresolved:alone:"), "{refused}");
        // A .mjs beside the .js is not an answer to the word: node runs server.js, which the digest names,
        // so the approval still holds.
        let server_mjs = dir.join("server.mjs");
        std::fs::write(&server_mjs, "export const run = 2;
").expect("server.mjs");
        assert!(approval_problem(&named, &spec("/usr/bin/node", &word)).is_ok(),
            "{:?}", approval_problem(&named, &spec("/usr/bin/node", &word)));
        // A directory is resolved by its index file, which is hashed in turn.
        let package_dir = dir.join("pkg");
        std::fs::create_dir_all(&package_dir).expect("scratch dir");
        let index = package_dir.join("index.js");
        std::fs::write(&index, "export const run = 4;
").expect("index.js");
        let folder = vec!["pkg".to_string()];
        let covered = approval("/usr/bin/node", &cwd, &[], &folder, &[&index], &["TOKEN"]);
        assert!(approval_problem(&covered, &spec("/usr/bin/node", &folder)).is_ok(),
            "{:?}", approval_problem(&covered, &spec("/usr/bin/node", &folder)));
        let _ = std::fs::remove_dir_all(&package_dir);
    }

    /// Finding 2: the interpreter families covered only JavaScript and shell, so python3 -c, perl -e,
    /// ruby -e and every interpreter's own module system passed - the program was the platform's and the
    /// code was a string nothing hashed. A program that IS such an interpreter is refused by name, and a
    /// code option given to a program the digest cannot classify is refused as inline code.
    #[test]
    fn an_interpreter_this_digest_cannot_follow_is_refused_by_name() {
        for program in ["/usr/bin/python3", "/usr/bin/python3.11", "/usr/bin/perl", "/usr/bin/ruby3.2",
                        "/usr/local/bin/deno", "/opt/bun", "/usr/bin/php8.2", "/usr/bin/lua5.4"] {
            let refused = super::program_shape_problem(program).expect("an unfollowed interpreter");
            assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{program}: {refused}");
            assert!(refused.contains("/mcp <id> probe"), "the way to approve it again is in it: {refused}");
        }
        // The two families the digest DOES follow stay approvable as programs.
        assert!(super::program_shape_problem("/usr/bin/node").is_none());
        assert!(super::program_shape_problem("/bin/sh").is_none());
        // A code option given to a program the digest cannot classify is still code, not a value, and
        // round 8 decides that from the FAMILY: a program outside node and the shells has no family of
        // its own, so every one of CODE_FLAGS is code. A native binary is the only such program the
        // allow-list lets through (as the operator's --native voucher), and it is judged here.
        let runner_path = scratch_native("runner");
        let runner = runner_path.to_string_lossy().to_string();
        let inline = vec!["-c".to_string(), "print(1)".to_string()];
        assert_eq!(super::interpreter_family(&runner), "unknown", "no family: every code flag is code");
        assert_eq!(super::inline_flag(&runner, "-c").as_deref(), Some("-c"), "a code flag, no family");
        assert_eq!(super::inline_flag(&runner, "-m").as_deref(), Some("-m"), "and so is -m");
        // Unvouched, the allow-list answers first: a native binary outside the two families needs the
        // operator's own voucher before its command line is even read.
        let coded = approval(&runner, "", &[], &inline, &[], &["TOKEN"]);
        let refused = approval_problem(&coded, &spec(&runner, &inline)).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        // Vouched for, the program passes the allow-list - and its inline code is STILL refused, because
        // a native binary's own loads are outside the digest and a string it evaluates is outside it too.
        let digest = sha256_hex(&std::fs::read(&runner_path).expect("the vouched binary"));
        let vouched = json!({"form": APPROVAL_FORM, "sha256": "00".repeat(32), "program": runner,
            "cwd": "", "env": [], "args": inline, "files": [runner.clone()], "vault": ["TOKEN"],
            "native": {"path": runner, "sha256": digest}});
        let refused = approval_problem(&vouched, &spec(&runner, &inline)).unwrap_err();
        assert!(refused.starts_with("vault_approval_inline_code:-c:"), "{refused}");
        // A shell script outside both families never reaches the flag rule: the allow-list refuses the
        // program itself, which is the point of an allow-list rather than a list of code flags.
        let scripted = scratch("runner-script", "#!/bin/sh\nexit 0\n");
        let scripted = scripted.to_string_lossy().to_string();
        let coded = approval(&scripted, "", &[], &inline, &[], &["TOKEN"]);
        let refused = approval_problem(&coded, &spec(&scripted, &inline)).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        // What node's own family names as a file stays a file (--require/-r), not inline code.
        let loads = scratch("loads.mjs", "export const load = 1;
");
        let require = vec!["-r".to_string(), loads.to_string_lossy().to_string()];
        let path_option = approval("/usr/bin/node", "", &[], &require, &[&loads], &["TOKEN"]);
        assert!(approval_problem(&path_option, &spec("/usr/bin/node", &require)).is_ok(),
            "{:?}", approval_problem(&path_option, &spec("/usr/bin/node", &require)));
        let _ = std::fs::remove_file(&runner);
    }

    /// Finding 3: the refusal said "no value was used", and it was not true - the value was put in the
    /// child's environment before the spawn, so a file rewritten between the check and the launch had
    /// already received it. The sentence is the operator's and it is compared verbatim here, so a later
    /// edit that softens it fails this test.
    #[test]
    fn a_change_after_the_check_names_the_value_as_exposed() {
        let script = scratch("exposed.mjs", "export const ok = 1;
");
        let verified = vec![(super::real_path(&script.to_string_lossy()),
            sha256_hex(&std::fs::read(&script).expect("the script")))];
        std::fs::write(&script, "export const ok = 2;
").expect("rewrite");
        let refused = super::recheck_after_spawn(&verified).expect("a rewrite is a mismatch");
        let expected = format!("vault_approval_changed_since_check:{}: a file this connector runs changed between the check and the launch, so the operation was killed - the value had already been put in its environment at launch, so treat it as exposed and rotate it if this change was not yours. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on", super::real_path(&script.to_string_lossy()));
        assert_eq!(refused, expected);
        let _ = std::fs::remove_file(&script);
    }

    /// Finding 4: the code files were hashed before the spawn and never again, so a rewrite that lands
    /// between the hash and the child's open was caught by nothing. The same bytes are now hashed after
    /// the spawn, and a mismatch kills the operation.
    #[test]
    fn a_rewrite_between_the_check_and_the_spawn_is_caught() {
        let script = scratch("recheck.mjs", "export const ok = 1;\n");
        let verified = vec![(super::real_path(&script.to_string_lossy()),
            sha256_hex(&std::fs::read(&script).expect("the script")))];
        assert!(super::recheck_after_spawn(&verified).is_none(), "the approved bytes are still there");
        std::fs::write(&script, "export const ok = 2;\n").expect("rewrite");
        let refused = super::recheck_after_spawn(&verified).expect("a rewrite is a mismatch");
        assert!(refused.starts_with("vault_approval_changed_since_check:"), "{refused}");
        // Not reading it is not passing it: a file that vanished is a mismatch too.
        std::fs::remove_file(&script).expect("remove");
        assert!(super::recheck_after_spawn(&verified).is_some(), "a file that cannot be read is a mismatch");
    }

    /// Item 1 of round 9: `--native` works END TO END. The kernel has two judgements about a program -
    /// approval_problem (the launch) and request_server_problem (the command the child spawns from the
    /// request file) - and only the first read the operator's voucher. A vouched ELF therefore passed the
    /// approval and was refused one step later, by the request check, so `/mcp <id> on --native` could
    /// never launch: the review's first item, and the reason both now take the same `program_refusal`
    /// judgement with the same voucher.
    #[test]
    fn a_vouched_native_binary_passes_the_approval_and_the_request_check() {
        let binary = scratch_native("vouched-node");
        let path = binary.to_string_lossy().to_string();
        // The launch as the console really builds it (lua/core/mcp.lua: `program=node_program()`): the
        // kernel spawns the interpreter, which spawns the connector's program from the request file. The
        // connector's program here is a native binary outside the two families, vouched for.
        // Host-independent (item 6): the spawned interpreter is a FIXTURE binary named node, not
        // /usr/bin/node, so this test says the same thing on a host that keeps node somewhere else - or
        // nowhere. A real ELF named `node` passes the allow-list by its name and its bytes.
        let runtime = scratch_native("node");
        let runtime_path = runtime.to_string_lossy().to_string();
        let client = scratch("native-client.mjs", "export const c = 1;\n");
        let request_path = scratch("native-request.json", "{}");
        let launch = spec(&runtime_path, &[client.to_string_lossy().to_string(),
            "--request-file".into(), request_path.to_string_lossy().to_string()]);
        let approved = approval_native(&binary, &[&binary, &client, &runtime], &["TOKEN"]);
        assert!(approval_problem(&approved, &launch).is_ok(),
            "a vouched native binary is a program the allow-list admits: {:?}",
            approval_problem(&approved, &launch));
        // The same command as the child reads it from the request file. This is the half that was missing.
        let sealed = request(&path, &[], None);
        assert!(request_server_problem(&sealed, &approved).is_ok(),
            "the request check carries the same voucher: {:?}",
            request_server_problem(&sealed, &approved));
        // The voucher admits a FILE, not the family: another native binary, unvouched, is refused by the
        // same allow-list it was refused by before this round.
        let other = scratch_native("unvouched-node");
        let other_path = other.to_string_lossy().to_string();
        let mut unvouched = approved.clone();
        unvouched["program"] = json!(other_path);
        unvouched["args"] = json!([]);
        let refused = request_server_problem(&request(&other_path, &[], None), &unvouched).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        // And WITHOUT the voucher the same approval is refused one step earlier, on the launch side: this
        // is what `--native` buys, and what its absence costs.
        let plain = approval(&path, "", &[], &[], &[&binary, &client, &runtime], &["TOKEN"]);
        let refused = approval_problem(&plain, &launch).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        let _ = std::fs::remove_file(&runtime);
        let _ = std::fs::remove_file(&binary);
        let _ = std::fs::remove_file(&other);
        let _ = std::fs::remove_file(&client);
        let _ = std::fs::remove_file(&request_path);
    }

    /// Item 1: each of the three native refusals is reached by a test of its own, from an approval the
    /// console really writes (the binary IS one of the files it names) - and each of them fires BEFORE a
    /// spawn, so a changed binary never runs.
    #[test]
    fn a_native_binary_that_changed_or_vanished_or_was_not_named_is_refused() {
        // Changed after the approval: the bytes on disk are not the bytes the operator vouched for.
        // Host-independent: a fixture interpreter named node stands in for the platform's.
        let runtime = scratch_native("node");
        let runtime_path = runtime.to_string_lossy().to_string();
        let binary = scratch_native("changed-node");
        let approved = approval_native(&binary, &[&binary, &runtime], &["TOKEN"]);
        let path = binary.to_string_lossy().to_string();
        use std::io::Write as _;
        std::fs::OpenOptions::new().append(true).open(&binary).expect("open")
            .write_all(b"\0").expect("append a byte");
        let refused = approval_problem(&approved, &spec(&runtime_path, &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_native_changed:"), "{refused}");
        assert!(refused.contains(&path), "the refusal names the binary: {refused}");

        // Gone after the approval: the console lists the vouched binary among the files, so this is the
        // read that fails first - and it says NATIVE, not "a script this connector was approved with".
        let vanished = scratch_native("vanished-node");
        let approved = approval_native(&vanished, &[&vanished, &runtime], &["TOKEN"]);
        let path = vanished.to_string_lossy().to_string();
        std::fs::remove_file(&vanished).expect("remove the vouched binary");
        let refused = approval_problem(&approved, &spec(&runtime_path, &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_native_unreadable:"), "{refused}");
        assert!(!refused.contains("a script this connector was approved with"),
            "a native binary that vanished is not reported as a script: {refused}");

        // A voucher for a file the approval does not name: the digest covers a file list, and a voucher
        // outside it would approve a binary nothing hashed.
        let outside = scratch_native("outside-node");
        let approved = approval_native(&outside, &[&runtime], &["TOKEN"]);
        let refused = approval_problem(&approved, &spec(&runtime_path, &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_native_not_covered:"), "{refused}");
        let _ = std::fs::remove_file(&outside);
        let _ = std::fs::remove_file(&runtime);
    }
}

/// MUST 3 (review r1): the relay's deadline must not kill ADOPTED work.
///
/// The relay stamps the caller's deadline and the node installs it as this run's cancel flag
/// (serve::install_relay_context). The FOREGROUND `bash` path observes that flag and cancels its own
/// operation (operations.rs, "A cancelled run or child cancels its operation too"); the adoption path
/// this mission added is `control("start")`, which is detached and must survive it.
///
/// This drives the REAL flag through the production seam (host::set_run_cancel_probe +
/// serve::test_set_run_cancel, the same pair subagents' cancel test uses) and asserts three things:
/// the flag is live in this process (foreground IS cancelled by it - the old bug), the adopted start is
/// NOT cancelled by it, and the command's marker holds exactly ONE line, so nothing was re-run.
///
/// Isolation: `manager()` roots its records under $HOME, which is a OnceLock - so this test REFUSES to
/// run unless HOME is a scratch/temp directory, and scripts/test.sh runs it with HOME=$GATE_HOME.
#[cfg(test)]
mod adoption_survives_the_relay_deadline {
    use super::*;
    use crate::host::shell_config;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    fn scratch_home_or_refuse() -> std::path::PathBuf {
        let home = std::path::PathBuf::from(std::env::var("HOME").unwrap_or_default());
        let text = home.to_string_lossy().to_string();
        let scratch = text.contains("tmp") || text.contains("temp") || text.contains("scratch")
            || text.contains("TMP");
        let real = text.ends_with("/.wasm-agent");
        assert!(scratch && !real,
            "refusing to run: this test starts real operations, so HOME must be a scratch or temp \
             directory and never the node's own ~/.wasm-agent (got {text}); scripts/test.sh runs it \
             with HOME=$GATE_HOME");
        home
    }

    #[test]
    fn an_adopted_operation_survives_the_relay_deadline_and_runs_once() {
        let home = scratch_home_or_refuse();
        let marker = home.join("adoption-marker.txt");
        std::fs::write(&marker, "").expect("marker");
        let marker_text = marker.to_string_lossy().to_string();
        let shell = shell_config();
        let session = "relay:review-test".to_string();

        // The production serve layer registers this probe before a turn; here the test registers it and
        // flips the same thread-local flag the probe reads, so the REAL host check is what runs.
        crate::host::set_run_cancel_probe(crate::serve::run_cancel_requested);
        let flag = Arc::new(AtomicBool::new(true));
        crate::serve::test_set_run_cancel(Some(flag.clone()));

        // 1. The flag is LIVE in this process: the foreground path cancels its own operation (the bug this
        // mission exists for). A test that did not prove this could pass while flipping nothing.
        let foreground = super::foreground(&shell.0, &shell.1, "sleep 5", "", 30, &serde_json::json!({}));
        assert!(foreground.is_err() || foreground.as_ref().map(|v| v["error"] == "run_cancelled"
                || v["ok"] == false).unwrap_or(false),
            "with the run cancelled, the foreground shell must be stopped, not reported done: {:?}",
            foreground.as_ref().map(|v| v["error"].clone()));

        // 2. Adoption: the same flag is still set, and this start must NOT be cancelled by it.
        let started = super::control("start", &serde_json::json!({
            "command": format!("printf 'run\\n' >> '{marker_text}'; sleep 3; echo adopted-done"),
            "cwd": "", "timeout_seconds": 60, "session": session, "background": true,
        }), &shell).expect("adopted start");
        let id = started["operation_id"].as_str().expect("operation id").to_string();

        // 3. It settles on its own, with the command's own result - not by the deadline.
        let settled = super::control("wait", &serde_json::json!({
            "id": id, "wait_ms": 20000, "session": session,
        }), &shell).expect("wait");
        crate::serve::test_set_run_cancel(None);
        assert_eq!(settled["settled"], serde_json::json!(true),
            "the adopted operation must settle by finishing, not by the run's cancel: {settled}");
        assert_ne!(settled["error"], serde_json::json!("cancelled"),
            "the adopted operation was CANCELLED by the relay deadline: {settled}");
        assert_eq!(flag.load(Ordering::SeqCst), true, "the flag stayed set the whole time");

        // 4. Exactly once: the marker holds ONE line, so the command was never re-run.
        let text = std::fs::read_to_string(&marker).expect("marker read");
        assert_eq!(text.matches("run").count(), 1,
            "the adopted command must have run exactly once, marker was {text:?}");
    }
}
