//! Rows for the P0: a supervisor must not outlive the node that started it.
//!
//! 395 supervisors were found adopted by the user manager (ppid=1) after their nodes died, and they made worker
//! sessions refuse `bash` with `background_descendants`. Two belts answer it, and each has its own row here:
//!   - the kernel's parent-death signal, which covers a node that is killed outright;
//!   - the `--owner-pid` watchdog, which covers a node that is not the parent (a re-parented or detached start).

use std::process::Command;
use std::time::{Duration, Instant};

#[cfg(target_os = "linux")]
fn alive(pid: i32) -> bool {
    extern "C" {
        fn kill(pid: i32, sig: i32) -> i32;
    }
    unsafe { kill(pid, 0) == 0 }
}

#[cfg(not(target_os = "linux"))]
fn alive(_pid: i32) -> bool {
    false
}

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_wa-operations-supervisor")
}

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("wa-orphan-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

fn wait_dead(pid: i32, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        if !alive(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    !alive(pid)
}

/// ROW: the parent goes, the supervisor goes. The parent here is `sh`, which starts the supervisor and exits: with
/// no parent-death signal the supervisor would be adopted by init and survive - exactly what the 395 were.
#[test]
fn the_supervisor_dies_with_the_process_that_started_it() {
    let dir = scratch("parent");
    let pidfile = dir.join("pid");
    let status = Command::new("sh")
        .arg("-c")
        .arg(format!(
            "{} --port 0 --rendezvous {}/r.json >/dev/null 2>&1 & echo $! > {}; sleep 0.5; exit 0",
            bin(),
            dir.display(),
            pidfile.display()
        ))
        .status()
        .expect("sh must run");
    assert!(status.success(), "the parent must exit normally");

    let pid: i32 = std::fs::read_to_string(&pidfile)
        .expect("the supervisor pid must be recorded")
        .trim()
        .parse()
        .expect("a pid");

    assert!(
        wait_dead(pid, Duration::from_secs(10)),
        "the supervisor ({pid}) outlived the process that started it"
    );
}

/// ROW: the owner is killed OUTRIGHT, and the supervisor still goes - `kill -9` leaves no shutdown path, which is
/// why the watchdog asks the kernel whether the owner pid is alive rather than waiting for a signal.
#[test]
fn the_supervisor_exits_when_its_named_owner_is_killed() {
    let dir = scratch("owner");
    let mut owner = Command::new("sleep").arg("60").spawn().expect("the owner must start");
    let owner_pid = owner.id();

    let mut supervisor = Command::new(bin())
        .arg("--port")
        .arg("0")
        .arg("--rendezvous")
        .arg(dir.join("r.json"))
        .arg("--owner-pid")
        .arg(owner_pid.to_string())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("the supervisor must start");
    let supervisor_pid = supervisor.id() as i32;

    // Let it come up, then kill the owner the way a crashed node dies: no signal it can handle.
    std::thread::sleep(Duration::from_millis(700));
    let _ = owner.kill();
    let _ = owner.wait();

    // A child that has exited but not been reaped is a ZOMBIE, and `kill(pid, 0)` succeeds for a zombie - the first
    // version of this row failed for that reason and not for a surviving supervisor. So: reap, then judge.
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut exited = false;
    while Instant::now() < deadline {
        if let Ok(Some(_)) = supervisor.try_wait() {
            exited = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(
        exited,
        "the supervisor ({supervisor_pid}) stayed alive after its owner ({owner_pid}) was killed"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
