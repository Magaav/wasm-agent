//! A fake kernel, for tests and for a smoke check of an install.
//!
//! This is `wa-watchdog selftest-kernel`. It exists because the tests need a process that behaves like a
//! kernel in the two ways the watchdog cares about - it binds one port and answers `GET /health` with a JSON
//! body, and it can be told to be unwell or to die - without a 40 MB binary, a node home or a database. It
//! touches nothing outside the port it was told to bind, so it cannot be a way to reach a live node.
//!
//! Modes, each of which is a failure the supervisor must handle:
//!   `--health ok`     answer 200 `{"ok":true,...}` (the healthy kernel)
//!   `--health fail`   answer 200 `{"ok":false,...}` (a served node that says it is not well)
//!   `--health down`   answer 503 (a process that is up but is not the service)
//!   `--health hang`   accept the connection and never answer (a wedged kernel)
//!   `--unhealthy-on-port N`  answer `ok:false` only when the port it bound is N - how a test proves a
//!                            binary on a spare port and fails it on the service port
//!   `--exit-after-ms N`      exit after N milliseconds (a crash loop)
//!   `--tag X`                report `"tag":"X"` in the body, so a test can tell which binary is answering

use std::io::{Read, Write};
use std::net::TcpListener;
use std::time::{Duration, Instant};

struct Args {
    port: u16,
    health: String,
    unhealthy_on_port: Option<u16>,
    tag: String,
    exit_after_ms: Option<u64>,
    bind_retry_ms: u64,
}

fn next(args: &[String], index: &mut usize, flag: &str) -> Result<String, String> {
    *index += 1;
    args.get(*index).cloned().ok_or_else(|| format!("{flag} needs a value"))
}

fn parse(args: &[String]) -> Result<Args, String> {
    let mut parsed = Args {
        port: std::env::var("WA_PORT").ok().and_then(|value| value.parse().ok()).unwrap_or(8799),
        health: "ok".to_string(),
        unhealthy_on_port: None,
        tag: String::new(),
        exit_after_ms: None,
        bind_retry_ms: 10_000,
    };
    let mut index = 0;
    while index < args.len() {
        let flag = args[index].as_str();
        match flag {
            "--port" => parsed.port = next(args, &mut index, flag)?.parse().map_err(|_| "--port expects a number".to_string())?,
            "--health" => parsed.health = next(args, &mut index, flag)?,
            "--unhealthy-on-port" => {
                parsed.unhealthy_on_port =
                    Some(next(args, &mut index, flag)?.parse().map_err(|_| "--unhealthy-on-port expects a number".to_string())?)
            }
            "--tag" => parsed.tag = next(args, &mut index, flag)?,
            "--exit-after-ms" => {
                parsed.exit_after_ms = Some(next(args, &mut index, flag)?.parse().map_err(|_| "--exit-after-ms expects a number".to_string())?)
            }
            "--bind-retry-ms" => {
                parsed.bind_retry_ms = next(args, &mut index, flag)?.parse().map_err(|_| "--bind-retry-ms expects a number".to_string())?
            }
            // The real kernel's own arguments are ignored, so this can stand in for `wa serve --port ...`.
            _ => {}
        }
        index += 1;
    }
    if parsed.tag.is_empty() {
        parsed.tag = std::env::current_exe()
            .ok()
            .and_then(|path| path.file_stem().map(|stem| stem.to_string_lossy().to_string()))
            .unwrap_or_else(|| "selftest-kernel".to_string());
    }
    Ok(parsed)
}

pub fn run(args: &[String]) -> i32 {
    let args = match parse(args) {
        Ok(args) => args,
        Err(error) => {
            eprintln!("selftest-kernel: {error}");
            return 2;
        }
    };
    // Binding can fail for a moment after the kernel this replaces was just killed: the stack may still be
    // reaping its socket (measured 138-176 ms on the node this was written for). A real kernel retries too.
    let deadline = Instant::now() + Duration::from_millis(args.bind_retry_ms);
    let listener = loop {
        match TcpListener::bind(("127.0.0.1", args.port)) {
            Ok(bound) => break bound,
            Err(error) => {
                if Instant::now() >= deadline {
                    eprintln!("selftest-kernel: cannot bind 127.0.0.1:{}: {error}", args.port);
                    return 1;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
        }
    };
    println!(
        "selftest-kernel listening on 127.0.0.1:{} (health {}, tag {})",
        args.port, args.health, args.tag
    );
    let _ = std::io::stdout().flush();

    let unhealthy = match args.health.as_str() {
        "fail" => true,
        "ok" => args.unhealthy_on_port == Some(args.port),
        _ => false,
    };
    let mode = args.health.clone();
    let tag = args.tag.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut stream = match stream {
                Ok(stream) => stream,
                Err(_) => continue,
            };
            let mode = mode.clone();
            let tag = tag.clone();
            std::thread::spawn(move || {
                let mut buffer = [0u8; 2048];
                let read = stream.read(&mut buffer).unwrap_or(0);
                let request = String::from_utf8_lossy(&buffer[..read]).to_string();
                if !request.starts_with("GET /health") {
                    let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                    return;
                }
                match mode.as_str() {
                    "hang" => {
                        std::thread::sleep(Duration::from_secs(30));
                    }
                    "down" => {
                        let body = format!("{{\"ok\":false,\"state\":\"down\",\"tag\":{}}}", crate::json::quote(&tag));
                        let response = format!(
                            "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        );
                        let _ = stream.write_all(response.as_bytes());
                    }
                    _ => {
                        let body = format!(
                            "{{\"ok\":{},\"state\":\"{}\",\"tag\":{}}}",
                            !unhealthy,
                            if unhealthy { "stalled" } else { "idle" },
                            crate::json::quote(&tag)
                        );
                        let response = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        );
                        let _ = stream.write_all(response.as_bytes());
                    }
                }
                let _ = stream.flush();
            });
        }
    });

    match args.exit_after_ms {
        // Counted from "it is listening", not from process start: a kernel waiting out a killed
        // predecessor's socket has not started yet, and a test that measured from exec would call a
        // perfectly good kernel a crash because the port was still being reaped.
        Some(after) => {
            std::thread::sleep(Duration::from_millis(after));
            println!("selftest-kernel exiting on purpose {after}ms after it started listening");
            let _ = std::io::stdout().flush();
            1
        }
        None => loop {
            std::thread::sleep(Duration::from_millis(1_000));
        },
    }
}
