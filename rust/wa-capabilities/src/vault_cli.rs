//! `wa vault …` — the CLI dispatch, in the crate that owns the node's commands.
//!
//! The implementation is `wa_vault::cli` (the vault's own engine and its `wa vault` parser), because the
//! CLI must be the same reader as the node: a second parser is a second chance to print a value where
//! only a name belongs. This module is the one line `rust/wa-host/src/main.rs` adds, in the command
//! table it owns:
//!
//! ```text
//! if args.first().is_some_and(|arg| arg == "vault") {
//!     if let Some(code) = wa_capabilities::vault_cli::run_node(&args) {
//!         std::process::exit(code);
//!     }
//! }
//! ```
//!
//! Until that line existed, `wa vault list` fell through to the Lua CLI and answered
//! `unknown command: vault` on every node that already carried the engine (found live, 08/11).
//!
//! **Which vault a node's command reaches.** The engine refuses to guess a directory: `--dir`, else
//! `WASM_AGENT_VAULT_DIR`, else nothing. The standalone `wa-vault` binary keeps that rule. The node's
//! own `wa` binds the default once, at startup ([`bind_default_dir`]), to [`vault_dir()`] — and that
//! binding is what makes *both* doors reach the same vault without either of them guessing:
//!
//! * `wa vault …` reads the variable through the engine (`wa_vault::cli::vault_dir`);
//! * `wa fleet sign|revoke|rotate|anchor --key vault:<name>` reads it through
//!   `wa_mesh::fleetchange::signer_for`, which takes `--vault-dir`, else the same variable.
//!
//! It is one rule instead of two defaults that could drift apart, and the value is the one
//! `wa_kernel_runtime::vault_host::default_dir` already uses.
use std::path::PathBuf;

/// Run `wa vault ...` as the node runs it. `Some(code)` when the arguments were a vault command
/// (whatever its outcome), so the caller can exit with it and never fall through to the Lua CLI.
pub fn run_node(args: &[String]) -> Option<i32> {
    wa_vault::cli::run(args)
}

/// The vault directory this node uses: `WASM_AGENT_VAULT_DIR`, else `<home>/.wasm-agent/vault`.
/// Non-secret, and the same answer `wa_kernel_runtime::vault_host::default_dir` gives.
pub fn vault_dir() -> PathBuf {
    match std::env::var_os(wa_vault::cli::DIR_ENV) {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => PathBuf::from(wa_host_support::paths::resolve_home()).join(".wasm-agent").join("vault"),
    }
}

/// Bind [`vault_dir`] as `WASM_AGENT_VAULT_DIR` for this process, unless the operator set it. Called
/// once by `wa`'s `main` before any command is dispatched, so `wa vault …` and `wa fleet … --key
/// vault:<name>` open the same vault. The value is a directory name, never a secret; a variable the
/// operator already set is left exactly as it is.
pub fn bind_default_dir() {
    let set = std::env::var_os(wa_vault::cli::DIR_ENV).is_some_and(|value| !value.is_empty());
    if !set {
        std::env::set_var(wa_vault::cli::DIR_ENV, vault_dir());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_vault_directory_is_under_the_node_home_and_is_not_a_guess_at_a_test_dir() {
        // `WASM_AGENT_VAULT_DIR` is not set for this process: the answer is the node's own directory.
        let dir = vault_dir();
        assert!(dir.to_string_lossy().ends_with("vault"), "{dir:?}");
        assert!(dir.to_string_lossy().contains(".wasm-agent"), "{dir:?}");
    }

    #[test]
    fn a_vault_subcommand_is_recognised_and_answers_its_usage() {
        // `help` is answered (exit 0) without touching a vault; an unknown subcommand is a refusal, so
        // the node never falls through to the Lua CLI and does not say `unknown command: vault` again.
        assert_eq!(run_node(&["vault".into(), "help".into()]), Some(0));
        assert_eq!(run_node(&["vault".into(), "describe".into()]), Some(1));
    }
}
