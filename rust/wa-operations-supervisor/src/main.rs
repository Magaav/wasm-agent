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


/// Linux: ask the kernel to signal us when our parent dies. Belt: `getppid()` already 1 means the parent went
/// before we asked, so exit now rather than wait for a signal that will never come.
#[cfg(target_os = "linux")]
fn die_with_parent() {
    const PR_SET_PDEATHSIG: i32 = 1;
    const SIGTERM: i32 = 15;
    extern "C" {
        fn prctl(option: i32, arg2: u64, arg3: u64, arg4: u64, arg5: u64) -> i32;
        fn getppid() -> i32;
    }
    unsafe {
        prctl(PR_SET_PDEATHSIG, SIGTERM as u64, 0, 0, 0);
        if getppid() == 1 {
            eprintln!("[operations-supervisor] parent already gone; exiting");
            std::process::exit(0);
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn die_with_parent() {}

/// Is `pid` still there? `kill(pid, 0)` is the portable-enough test: no signal is sent, an error means gone.
#[cfg(target_os = "linux")]
fn alive(pid: u32) -> bool {
    extern "C" {
        fn kill(pid: i32, sig: i32) -> i32;
    }
    unsafe { kill(pid as i32, 0) == 0 }
}

#[cfg(not(target_os = "linux"))]
fn alive(_pid: u32) -> bool { true }

/// The second belt: the node names itself on the command line, and we exit when that process is gone. A killed
/// node cannot run a shutdown path, so this check is what makes the promise true for `kill -9` as well.
fn watch_owner(pid: u32) {
    std::thread::spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_millis(500));
        if !alive(pid) {
            eprintln!("[operations-supervisor] owner {pid} is gone; exiting");
            std::process::exit(0);
        }
    });
}

fn main() {
    die_with_parent();
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        println!("usage: wa-operations-supervisor [--port 8791] [--rendezvous <file>] [--owner-pid <pid>]\n  own this node's supervised operations (blocks until stopped)\n  the node reaches it through <home>/.wasm-agent/operations-supervisor.json, which this program writes (no environment variable decides it)");
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
    if let Some(owner) = flag(&args, "--owner-pid").and_then(|value| value.parse::<u32>().ok()) {
        watch_owner(owner);
    }
    if let Err(error) = server::serve(rendezvous, port) {
        eprintln!("operations-supervisor: {error}");
        std::process::exit(1);
    }
}
