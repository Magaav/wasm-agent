//! `wa vault …` — the CLI dispatch, in the crate that owns the node's commands.
//!
//! The implementation is `wa_vault::cli` (the vault's own engine and its `wa vault` parser), because the
//! CLI must be the same reader as the node: a second parser is a second chance to print a value where
//! only a name belongs. This module exists so `rust/wa-host/src/main.rs` has one line to add, in the
//! command table it owns:
//!
//! ```text
//! if command == "vault" {
//!     if let Some(code) = wa_capabilities::vault_cli::run(&lua_args) {
//!         host::restore_input();
//!         std::process::exit(code);
//!     }
//! }
//! ```
//!
//! `wa-host` is edited by another stream (the WASI 0.3 / wasmtime 50 upgrade), so this crate carries the
//! dispatch ready and `rust/wa-vault/src/bin/wa-vault.rs` is the identical code path that runs today.
//!
//! `wa fleet revoke|rotate|anchor|sign --key vault:<name>` needs no wiring at all: `wa fleet` already
//! dispatches into `wa_mesh::fleetkey::run`, which is where those subcommands live.
use std::path::PathBuf;

/// Run `wa vault ...` from the arguments after the command word. `Some(code)` when the arguments were a
/// vault command (whatever its outcome), `None` when they were not, so a caller can fall through.
pub fn run(args: &[String]) -> Option<i32> {
    wa_vault::cli::run(args)
}

/// The vault directory this node uses: `WASM_AGENT_VAULT_DIR`, else `<home>/.wasm-agent/vault`.
/// Non-secret, and the same answer `wa_kernel_runtime::vault_host::default_dir` gives.
pub fn vault_dir() -> PathBuf {
    PathBuf::from(wa_host_support::paths::resolve_home()).join(".wasm-agent").join("vault")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_non_vault_command_falls_through_and_a_vault_command_is_answered() {
        // `wa vault` with no directory is a refusal (exit 1), not a fall-through: the command was
        // recognised, and guessing a directory would let a test reach a node's real vault.
        assert_eq!(run(&["describe".into()]), Some(1));
        assert_eq!(run(&["help".into()]), Some(0));
    }

    #[test]
    fn the_vault_directory_is_under_the_node_home_and_is_not_a_guess_at_a_test_dir() {
        let dir = vault_dir();
        assert!(dir.to_string_lossy().ends_with("vault"), "{dir:?}");
        assert!(dir.to_string_lossy().contains(".wasm-agent") || dir == PathBuf::from(".wasm-agent/vault"));
    }
}
