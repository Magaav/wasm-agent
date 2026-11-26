//! The operations supervisor as its own program (`ready-operations-slice-2.md`, stage B).
//!
//! It owns what the node must stop carrying: one supervised external execution with an identity, an owner, an
//! absolute budget, output cursors, cancellation and a terminal outcome. The node reaches it over the loopback
//! wire slice 1 built, with the same JSON in and out.
//!
//! What it can answer for itself it does (`facts.rs`): the pure file questions, the disk cap, the progress rows
//! (one file per owner, the same store the node reads), and its own run/cancel flags. What it cannot know - the
//! node's in-turn marker, its subagent context, its relay deadline - the node sends with the request.
mod facts;
mod server;

use std::path::PathBuf;

fn flag(args: &[String], name: &str) -> Option<String> {
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == name {
            return iter.next().cloned();
        }
        if let Some(value) = arg.strip_prefix(&format!("{name}=")) {
            return Some(value.to_string());
        }
    }
    None
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        println!("usage: wa-operations-supervisor [--port 8791] [--rendezvous <file>]\n  own this node's supervised operations (blocks until stopped)\n  the node reaches it through WASM_AGENT_OPERATIONS_SUPERVISOR=<the rendezvous file>");
        return;
    }
    let port = flag(&args, "--port").and_then(|value| value.parse().ok()).unwrap_or(8791);
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    let rendezvous = flag(&args, "--rendezvous")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(home).join(".wasm-agent/operations-supervisor.json"));
    // The facts go in BEFORE any verb can ask for one: an operation that ran on the defaults would record no
    // progress row and check no disk cap, which is a silent difference from the node's own path.
    wa_operations_runner::node::install(&facts::SupervisorFacts);
    if let Err(error) = server::serve(rendezvous, port) {
        eprintln!("operations-supervisor: {error}");
        std::process::exit(1);
    }
}
