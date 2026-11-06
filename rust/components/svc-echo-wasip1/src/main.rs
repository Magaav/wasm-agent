//! Fixture service: proves the runner's contract with the raw host imports.
use std::time::Duration;

#[link(wasm_import_module = "wa_sock")]
extern "C" {
    fn connect(ptr: *const u8, len: i32) -> i32;
    fn read(h: i32, ptr: *mut u8, len: i32) -> i32;
    fn write(h: i32, ptr: *const u8, len: i32) -> i32;
    fn close(h: i32) -> i32;
}
#[link(wasm_import_module = "wa_ctl")]
extern "C" {
    fn stopping() -> i32;
}

fn dial(addr: &str) -> i32 {
    unsafe { connect(addr.as_ptr(), addr.len() as i32) }
}

fn main() {
    let config: serde_json::Value = std::env::var("WA_COMPONENT_CONFIG").ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
    if config["crash"] == true {
        println!("crashing on purpose");
        std::thread::sleep(Duration::from_millis(200));
        std::process::exit(3);
    }
    println!("heartbeat start");
    if let Some(addr) = config["dial"].as_str() {
        let h = dial(addr);
        if h >= 0 {
            let msg = b"ping";
            unsafe { write(h, msg.as_ptr(), msg.len() as i32) };
            let mut buf = [0u8; 16];
            let mut got = 0;
            for _ in 0..500 {
                let n = unsafe { read(h, buf.as_mut_ptr(), buf.len() as i32) };
                if n > 0 { got = n; break; }
                if n == 0 || (n < 0 && n != -11) { break; }
                std::thread::sleep(Duration::from_millis(2));
            }
            println!("{}", if &buf[..got.max(0) as usize] == b"ping" { "echo ok" } else { "echo failed" });
            unsafe { close(h) };
        } else {
            println!("dial failed {h}");
        }
    }
    if let Some(addr) = config["refused"].as_str() {
        println!("refused {}", dial(addr));
    }
    loop {
        if unsafe { stopping() } == 1 {
            println!("stopping cleanly");
            return;
        }
        println!("heartbeat");
        std::thread::sleep(Duration::from_millis(300));
    }
}
