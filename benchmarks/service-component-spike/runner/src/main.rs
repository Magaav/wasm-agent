//! Spike runner: a wasip1 core module + `wa_sock` host imports (non-blocking TCP to allowlisted
//! addresses only). Proves a Go guest can run whatsmeow's TLS/websocket dial through the host.
use std::io::{ErrorKind, Read, Write};
use std::net::TcpStream;
use wasmtime::{Caller, Engine, Linker, Module, Store};
use wasmtime_wasi::p1::{self, WasiP1Ctx};
use wasmtime_wasi::WasiCtxBuilder;

struct State { wasi: WasiP1Ctx, socks: Vec<Option<TcpStream>>, allow: Vec<String> }

fn mem<'a>(c: &'a mut Caller<'_, State>) -> wasmtime::Memory { c.get_export("memory").unwrap().into_memory().unwrap() }
const EAGAIN: i32 = -11;

fn main() -> anyhow::Result<()> {
    let path = std::env::args().nth(1).expect("module");
    let engine = Engine::default();
    let module = Module::from_file(&engine, &path)?;
    let mut linker: Linker<State> = Linker::new(&engine);
    p1::add_to_linker_sync(&mut linker, |s: &mut State| &mut s.wasi)?;
    linker.func_wrap("wa_sock", "connect", |mut c: Caller<'_, State>, ptr: i32, len: i32| -> i32 {
        let m = mem(&mut c);
        let mut buf = vec![0u8; len as usize];
        if m.read(&c, ptr as usize, &mut buf).is_err() { return -1; }
        let addr = String::from_utf8_lossy(&buf).into_owned();
        if !c.data().allow.contains(&addr) { eprintln!("refused {addr}"); return -13; }
        match TcpStream::connect(&addr) {
            Ok(s) => { s.set_nonblocking(true).ok(); s.set_nodelay(true).ok(); let st = c.data_mut(); st.socks.push(Some(s)); (st.socks.len() - 1) as i32 }
            Err(_) => -1,
        }
    })?;
    linker.func_wrap("wa_sock", "read", |mut c: Caller<'_, State>, h: i32, ptr: i32, n: i32| -> i32 {
        let mut buf = vec![0u8; n as usize];
        let r = match c.data_mut().socks.get_mut(h as usize).and_then(|s| s.as_mut()) { Some(s) => s.read(&mut buf), None => return -9 };
        match r {
            Ok(k) => { let m = mem(&mut c); if m.write(&mut c, ptr as usize, &buf[..k]).is_err() { return -1; } k as i32 }
            Err(e) if e.kind() == ErrorKind::WouldBlock => EAGAIN,
            Err(_) => -1,
        }
    })?;
    linker.func_wrap("wa_sock", "write", |mut c: Caller<'_, State>, h: i32, ptr: i32, n: i32| -> i32 {
        let m = mem(&mut c);
        let mut buf = vec![0u8; n as usize];
        if m.read(&c, ptr as usize, &mut buf).is_err() { return -1; }
        match c.data_mut().socks.get_mut(h as usize).and_then(|s| s.as_mut()) {
            Some(s) => match s.write(&buf) { Ok(k) => k as i32, Err(e) if e.kind() == ErrorKind::WouldBlock => EAGAIN, Err(_) => -1 },
            None => -9,
        }
    })?;
    linker.func_wrap("wa_sock", "close", |mut c: Caller<'_, State>, h: i32| -> i32 {
        if let Some(slot) = c.data_mut().socks.get_mut(h as usize) { *slot = None; } 0
    })?;
    let wasi = WasiCtxBuilder::new().inherit_stdout().inherit_stderr().build_p1();
    let mut store = Store::new(&engine, State { wasi, socks: Vec::new(), allow: vec!["web.whatsapp.com:443".into()] });
    let instance = linker.instantiate(&mut store, &module)?;
    let start = instance.get_typed_func::<(), ()>(&mut store, "_start")?;
    match start.call(&mut store, ()) {
        Ok(()) => {}
        Err(e) => if let Some(exit) = e.downcast_ref::<wasmtime_wasi::I32Exit>() { if exit.0 != 0 { eprintln!("exit {}", exit.0) } } else { return Err(e) },
    }
    Ok(())
}
