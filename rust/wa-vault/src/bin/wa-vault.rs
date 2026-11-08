//! `wa-vault` — the same `wa vault ...` dispatch, reachable today.
//!
//! `rust/wa-host/src/main.rs` owns the `wa <command>` table and is edited by another stream, so the
//! three lines that would route `wa vault` there are listed in `REPORT.md` instead of being made here.
//! This binary is the identical code path (`wa_vault::cli::run`), which is what the tests and the
//! smoke run use: `cargo run -q -p wa-vault --bin wa-vault -- list --dir <temp>`.
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match wa_vault::cli::run(&args) {
        Some(code) => std::process::exit(code),
        None => std::process::exit(2),
    }
}
