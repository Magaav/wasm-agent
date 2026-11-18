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
// asks for, EVERY file it can run or load (v2: the closure of what those files import in turn) and the
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
/// against a digest it could never match: v2 covers the launch's directory and its plain (non-vault)
/// environment as well as its bytes, and v2's file list is the CLOSURE of the code the connector loads.
const APPROVAL_FORM: &str = "mcp-vault-approval/v2";

fn approval_text(program: &str, cwd: &str, env: &[(String, String)], args: &[String],
                 files: &[(String, String)], vault: &[String]) -> String {
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
    for name in vault { text.push_str(&format!("vault {}\n", approval_field(name))); }
    text
}

fn sha256_hex(bytes: &[u8]) -> String {
    use ring::digest::{digest, SHA256};
    digest(&SHA256, bytes).as_ref().iter().map(|byte| format!("{byte:02x}")).collect()
}

/// An absolute path whose extension says it is a script: the launch's own arguments the approval must
/// cover. An extension is a name and this is the only thing it is used as - the digest is over BYTES.
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
const PLATFORM_ROOTS: [&str; 14] = ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/lib/",
    "/usr/lib64/", "/usr/libexec/", "/lib/", "/lib64/", "/usr/local/bin/", "/usr/local/sbin/",
    "/opt/homebrew/", "/nix/store/", "/snap/"];
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

/// A program under one of these is the platform's (the interpreter the connector runs ON), not the
/// connector's own code: /usr/bin/node is replaced by a package manager, never by the agent.
fn platform_root(path: &str) -> bool {
    let normalized = path.replace('\\', "/").to_lowercase();
    PLATFORM_ROOTS.iter().any(|root| normalized.starts_with(root))
}

/// A path-shaped argument is one the launch could read: it has a separator, or it carries a script
/// extension. A URL is data, never a local path.
fn looks_like_path(value: &str) -> bool {
    if value.is_empty() || value.contains("://") { return false; }
    if value.contains('/') || value.contains('\\') { return true; }
    std::path::Path::new(value).extension().and_then(|ext| ext.to_str())
        .is_some_and(|ext| SCRIPT_EXTENSIONS.iter().any(|known| ext.eq_ignore_ascii_case(known)))
}

/// Why a program cannot be covered, or None when it can: a bare name is resolved through PATH, which the
/// digest does not name, and a package runner's code comes from a cache or a registry.
fn program_shape_problem(program: &str) -> Option<String> {
    let name = basename(program);
    if PACKAGE_RUNNERS.contains(&name.as_str()) {
        return Some(format!("vault_approval_package_runner:{program}: this connector's program is a package runner ({name}), whose code comes from a cache or a registry rather than from files an approval can name, so nothing was launched and no value was read. Give it its own absolute program at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
    }
    if !is_absolute_path(program) {
        return Some(format!("vault_approval_program_not_absolute:{program}: this connector's program is a bare name, which is resolved through PATH rather than named by the digest, so nothing was launched and no value was read. Name the absolute path of its interpreter or binary: /mcp <id> probe, then /mcp <id> on"));
    }
    None
}

/// Nothing is launched and no value is read unless the launch matches the approval the operator gave.
/// Each refusal names what is wrong and what to do, because the reader of a refusal is the one who can
/// approve the connector again.
fn approval_problem(approval: &Value, launch: &Spec) -> Result<(), String> {
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
    let mut files: Vec<(String, String)> = Vec::new();
    for entry in approval["files"].as_array().map(Vec::as_slice).unwrap_or_default() {
        let path = entry.as_str().unwrap_or_default();
        if path.is_empty() {
            return Err("vault_approval_required: this connector carries an approval with no script list, so no value was read. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on".into());
        }
        let Ok(bytes) = std::fs::read(path) else {
            return Err(format!("vault_approval_unreadable:{path}: a script this connector was approved with cannot be read now, so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
        };
        files.push((path.to_string(), sha256_hex(&bytes)));
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
    // program outside the platform's roots is its own code.
    if let Some(problem) = program_shape_problem(&program) { return Err(problem); }
    for arg in args.iter().filter(|arg| looks_like_path(arg)) {
        if !is_absolute_path(arg) {
            return Err(format!("vault_approval_path_not_absolute:{arg}: this connector runs a path relative to its own directory, which the digest cannot name, so nothing was launched and no value was read. Name its absolute path: /mcp <id> probe, then /mcp <id> on"));
        }
    }
    if !platform_root(&program) && !files.iter().any(|(path, _)| path == &program) {
        return Err(format!("vault_approval_program_not_covered:{program}: this connector's own program is not a file the approval names, so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
    }
    let digest = sha256_hex(approval_text(&program, &cwd, &env, &args, &files, &vault).as_bytes());
    if !digest.eq_ignore_ascii_case(&expected) {
        return Err(format!("vault_approval_mismatch: this connector's program, arguments or scripts changed after the operator approved it, so nothing was launched and no value was read (approved {expected}, now {digest}). Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
    }
    Ok(())
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
    if let Some(problem) = program_shape_problem(program) { return Err(problem); }
    let files = string_list(approval.get("files"));
    for arg in args.iter().filter(|arg| looks_like_path(arg)) {
        if !is_absolute_path(arg) {
            return Err(format!("vault_request_path_not_absolute:{arg}: this request runs a path relative to the connector's own directory, which the approval cannot name, so nothing was launched and no value was read. Name its absolute path: /mcp <id> probe, then /mcp <id> on"));
        }
        if std::path::Path::new(arg).is_file() && !files.iter().any(|path| path == arg) {
            return Err(format!("vault_request_file_not_covered:{arg}: this request runs a file the approval does not name, so nothing was launched and no value was read. Approve the connector again at the operator's terminal: /mcp <id> probe, then /mcp <id> on"));
        }
    }
    if !platform_root(program) && !files.iter().any(|path| path == program) {
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
pub fn manager() -> &'static Manager {
    static MANAGER: OnceLock<Manager> = OnceLock::new();
    MANAGER.get_or_init(|| {
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
fn spec(launch: &Launch, cwd: &str, seconds: u64, owner: String, promote: bool) -> Spec {
    configure_spec(
        Spec::command(launch.program.clone(), launch.args.clone()),
        cwd,
        seconds,
        owner,
        promote,
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

fn configure_spec(mut spec: Spec, cwd: &str, seconds: u64, owner: String, promote: bool) -> Spec {
    spec.cwd = cwd.into();
    spec.timeout = Duration::from_secs(seconds);
    // A foreground `bash` adopts a descendant tree it cannot wait for; a deliberately
    // started operation is already background and never needs to.
    spec.promote_descendants = promote;
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
    let stderr = state["stderr_path"].as_str().unwrap_or("");
    let elapsed = state["elapsed_ms"].as_u64().unwrap_or(0) as f64 / 1000.0;
    crate::tool_progress::tick(id, tool, crate::tool_progress::now_epoch() - elapsed, stdout, stderr);
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
pub fn control(action: &str, args: &Value, shell: &(String, String)) -> Result<Value, String> {
    let id = args["id"].as_str().unwrap_or("");
    let result = match action {
        "start" => {
            if args.get("replay_of").is_some(){return Err("operation_replay_forbidden: inspect original and make a separately authorized decision".into());}
            let owner = args["owner"].as_str().unwrap_or("").to_string();
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
                    crate::host::executable_on_path(&name).ok_or("program_not_found_on_path")?
                };
                let argv=args["args"].as_array().ok_or("program_args_required")?.iter()
                    .map(|arg|arg.as_str().map(String::from).ok_or("program_args_must_be_strings"))
                    .collect::<Result<Vec<_>,_>>()?;
                configure_spec(Spec::command(executable,argv),cwd,seconds,owner,false)
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
                )
            };
            // `vault_env` ({ENV: entry}): the kernel puts a node-vault entry in the child's environment, so a
            // connector's credential is used by reference and never passes through Lua, a request file or a
            // transcript (operator 17/11 "its credential should be in the vault"). Only the kernel's own
            // callers send it (the MCP client and session); the generic operation route strips it.
            let mut launch = launch;
            let vault_launch = args.get("vault_env").and_then(|value| value.as_object()).is_some();
            if let Some(map) = args.get("vault_env").and_then(|value| value.as_object()) {
                // The approval comes FIRST: a launch whose program, arguments or scripts no longer
                // match what the operator approved reads no value at all (docs/VAULT.md).
                approval_problem(args.get("vault_approval").unwrap_or(&Value::Null), &launch)?;
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
            let id = manager()
                .start(launch_context(launch, &args["_launch_cwd"]))
                .map_err(|e| e.to_string())?;
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
            for key in ["cwd", "cwd_requested", "cwd_source", "effective_cwd", "cwd_substitution", "cwd_note"] {
                if let Some(value) = state.get(key) { receipt[key] = value.clone(); }
            }
            return Ok(receipt);
        }
        "list" => return Ok(manager().list()),
        "relevant" => manager().relevant(
            args["cwd"].as_str().unwrap_or(""),
            args["after"].as_str().unwrap_or(""),
            args["limit"].as_u64().unwrap_or(64).min(256) as usize,
        ),
        "index" => manager().import_index(args["evidence"].as_str().unwrap_or("")),
        "reconcile" => manager().reconcile(args),
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
        "status" => manager().snapshot(id),
        "await" => {
            // Foreground bash can complete while its adopted descendants remain supervised.
            // Default to the command boundary for those operations; explicit operation start
            // and wait_for=settled retain full process-tree settlement semantics.
            let wait_for = args["wait_for"].as_str().unwrap_or("command");
            if wait_for != "command" && wait_for != "settled" {
                return Err("invalid_wait_for:expected_command_or_settled".into());
            }
            let tool = args["tool"].as_str().filter(|name| !name.is_empty()).unwrap_or("operation");
            loop {
                let state = manager()
                    .wait(id, Duration::from_millis(250))
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
                crate::serve::beat();
            }
        }
        "cancel" => {
            let stopped = manager().cancel(id);
            // A cancelled call is over: its row goes with it.
            crate::tool_progress::finish(id);
            stopped
        }
        // A caller polling an operation is the other place that owns its tail for a while (the
        // `operation` tool's own loop, the window's `/operation` read): refresh the row while it
        // waits, so a long call that the model is watching says what it is doing.
        "wait" => {
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
        "read" => manager().read(
            id,
            args["stream"].as_str().unwrap_or("stdout"),
            args["offset"].as_u64().unwrap_or(0),
            args["limit"].as_u64().unwrap_or(8192) as usize,
        ),
        _ => return Err("unknown_operation_action".into()),
    };
    result.map_err(|e| e.to_string())
}
pub fn health() -> Value {
    let entries = manager().list();
    json!(entries.as_array().unwrap().iter().filter(|s|s["settled"]!=true).map(|s|json!({"operation_id":s["operation_id"],"owner":s["owner"],"state":s["state"],"elapsed_ms":s["elapsed_ms"],"timeout_ms":s["timeout_ms"],"cleanup_budget_ms":s["cleanup_budget_ms"],"overdue":s["overdue"],"output_bytes":s["output_bytes"]})).collect::<Vec<_>>())
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
mod deadline_note_tests {
    use super::deadline_note;
    use serde_json::json;

    #[test]
    fn child_shell_is_marked_in_turn_and_cannot_request_installation() {
        use crate::subagents::{TaskContext,Provenance,SocketSlot};
        use std::sync::{Arc,atomic::AtomicBool};
        crate::subagents::enter_task(TaskContext{cancel:Arc::new(AtomicBool::new(false)),deadline:None,
            sockets:SocketSlot::default(),owner:"child-fixture".into(),provenance:Provenance::Child});
        let spec=super::configure_spec(wa_operation::Spec::command("fixture",vec![]),"",1,"".into(),false);
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

    // `\` and `"` escape to two units, so a quote-heavy command reaches the bound sooner.
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
        let digest = sha256_hex(approval_text(program, cwd, &env, args, &list, &vault).as_bytes());
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
        );
        assert!(text.starts_with("mcp-vault-approval/v2\nprogram /usr/bin/node\ncwd /home/agent/work%20tree\n"), "{text}");
        assert!(text.contains("\nenv LANG=LC_ALL\nenv MAIL_USER=MAIL_USER\narg "), "the plain environment is sorted by name: {text}");
        assert!(text.contains("\narg a%20b\n"), "a space is escaped, not a separator: {text}");
        assert_eq!(sha256_hex(text.as_bytes()),
            "7f39ce1281d1d72569286777c962d21ba85bef383c4bf77d1e883ffe4135b75b",
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
        let binary = scratch("home-conn", "#!/bin/sh\necho value\n");
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
        let _ = std::fs::remove_file(&binary);
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
        let binary = scratch("request-conn", "#!/bin/sh\necho value\n");
        let program = binary.to_string_lossy().to_string();
        let mut outside = approved.clone();
        outside["program"] = json!(program);
        outside["args"] = json!([]);
        assert!(request_server_problem(&request(&program, &[], None), &outside).unwrap_err()
            .starts_with("vault_request_program_not_covered:"));
        let _ = std::fs::remove_file(&client);
        let _ = std::fs::remove_file(&binary);
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
        let _ = std::fs::remove_dir_all(&dir);
    }
}
