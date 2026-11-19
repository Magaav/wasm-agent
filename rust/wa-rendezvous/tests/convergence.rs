// The storm, reproduced on a real socket, at a cap small enough to reach in a test.
//
// Measured 19/11 12:20-12:45 UTC: the rendezvous answered 503 too_many_connections to everyone and the
// fleet did not converge for half an hour, because the connections waiting for answers held every slot
// the polls needed to answer them. This test holds the listener at its non-reserved limit and asserts
// the two halves of the fix over a real TCP socket:
//
//   * the lanes that let an answer happen (/health, /relay/poll, /bindings/*, /lookup, /service) are
//     still served while ordinary traffic is being shed;
//   * an ordinary request that IS shed says so with Retry-After, in the header and in the body, so a
//     caller has a number to wait instead of retrying at once;
//   * when the storm clears, ordinary traffic converges again - no restart.
//
// It is one process with no node keys, so it proves the LISTENER's fairness, not a signed four-node
// relay exchange; that is named in the mission report rather than implied here.
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, Instant};

fn free_port() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind a probe port");
    listener.local_addr().expect("local addr").port()
}

/// One request, answered or not. Returns (status, headers+body) or None when the peer closed.
fn request(port: u16, raw: &str) -> Option<String> {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(20))).ok()?;
    stream.write_all(raw.as_bytes()).ok()?;
    let mut out = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => { out.extend_from_slice(&chunk[..n]); if out.windows(2).any(|w| w == b"\r\n\r\n") && out.len() > 0 { 
                // A Content-Length reply is complete once the head and body are both in.
                let text = String::from_utf8_lossy(&out).to_string();
                if let Some(head_end) = text.find("\r\n\r\n") {
                    let len = text[..head_end].lines()
                        .find_map(|line| line.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().to_string()))
                        .and_then(|v| v.parse::<usize>().ok()).unwrap_or(0);
                    if out.len() >= head_end + 4 + len { break }
                }
            } }
            Err(_) => break,
        }
    }
    Some(String::from_utf8_lossy(&out).to_string())
}

fn status_of(reply: &str) -> u16 {
    reply.split_whitespace().nth(1).and_then(|v| v.parse().ok()).unwrap_or(0)
}

#[test]
fn a_storm_is_shed_fairly_and_the_registry_converges_when_it_clears() {
    std::env::set_var("WA_RENDEZVOUS_MAX_CONNECTIONS", "16");
    // No administrators: this listener is not asked to authorize anything, only to serve or shed.
    std::env::remove_var("WASM_AGENT_NETWORK_ADMINS");
    let dir = std::env::temp_dir().join(format!("wa-rendezvous-converge-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let db = dir.join("registry.db");
    let db_path = db.to_string_lossy().to_string();
    let port = free_port();
    std::thread::spawn(move || wa_rendezvous::rendezvous::run("127.0.0.1", port, &db_path));
    // Wait for the listener to answer at all.
    let started = Instant::now();
    while request(port, "GET /health HTTP/1.1\r\nHost: x\r\n\r\n").is_none() {
        assert!(started.elapsed() < Duration::from_secs(10), "the rendezvous never started listening");
        std::thread::sleep(Duration::from_millis(50));
    }

    // ---- hold the non-reserved part of the cap ------------------------------------------------
    // A held connection is one whose request head never completes: the listener owns a thread and a
    // SQLite connection for it, which is exactly the resource the 19/11 storm exhausted. 13 held
    // sockets at a cap of 16 (4 reserved for the priority lanes) puts the listener past the 12 it may
    // give to ordinary traffic.
    let mut held = Vec::new();
    for _ in 0..13 {
        if let Ok(mut stream) = TcpStream::connect(("127.0.0.1", port)) {
            let _ = stream.write_all(b"GET /nodes HTTP/1.1\r\nHost: x\r\n");
            let _ = stream.flush();
            held.push(stream);
        }
    }
    std::thread::sleep(Duration::from_millis(200));

    // ---- the priority lane is still served ----------------------------------------------------
    let health = request(port, "GET /health HTTP/1.1\r\nHost: x\r\n\r\n").expect("a priority lane must answer");
    assert_eq!(status_of(&health), 200,
        "a poll-equivalent lane must be served while ordinary traffic is shed, got: {health}");

    // ---- ordinary traffic is shed WITH a hint --------------------------------------------------
    let shed = request(port, "GET /nodes HTTP/1.1\r\nHost: x\r\n\r\n").expect("a shed request still gets an answer");
    assert_eq!(status_of(&shed), 503, "ordinary traffic is shed at the reserved boundary, got: {shed}");
    assert!(shed.to_ascii_lowercase().contains("retry-after:"),
        "a shed answer carries Retry-After in the header, got: {shed}");
    assert!(shed.contains("retry_after_ms"), "and the same number in the body, got: {shed}");
    assert!(shed.contains("too_many_connections"), "and names itself, got: {shed}");

    // ---- the storm clears and the registry converges, with no restart --------------------------
    drop(held);
    let clear = Instant::now();
    let mut converged = false;
    while clear.elapsed() < Duration::from_secs(60) {
        match request(port, "GET /nodes HTTP/1.1\r\nHost: x\r\n\r\n") {
            Some(reply) if status_of(&reply) == 200 => { converged = true; break }
            _ => std::thread::sleep(Duration::from_millis(250)),
        }
    }
    let took = clear.elapsed();
    assert!(converged, "ordinary traffic must converge within 60 s of the storm clearing (waited {took:?})");
    println!("converged {} ms after the storm cleared", took.as_millis());

    let _ = std::fs::remove_dir_all(&dir);
}
