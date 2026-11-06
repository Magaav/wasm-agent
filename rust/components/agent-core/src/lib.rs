//! agent-core: the Lua core inside a wasm32-wasip2 component (docs/KERNEL.md, "A2.1", "A2.2").
//!
//! glue.c owns the interpreter; this file only crosses the component boundary: `rust_host_call`
//! turns the C-side argument array into `wa:kernel/host` values and back, `run` is the export, and
//! `rust_host_open`/`rust_host_next`/`rust_host_close` are the stream form (`http_sse`'s line
//! callback driven from the guest, one line per call).
use std::ffi::{c_char, c_int};

wit_bindgen::generate!({ world: "core-component", path: "../../../wit/kernel" });

use wa::kernel::host::{close, next, open, call, Value, Verdict};

/// One argument or result as glue.c lays it out. `kind`: 0 nil, 1 boolean (`int` 0/1),
/// 2 integer, 3 number, 4 bytes (`ptr`, `len`), 5 string map (`int` entries follow as key/value
/// byte slots, results only), 6 the JSON text of a Lua table (`ptr`, `len`).
#[repr(C)]
pub struct Slot {
    kind: c_int,
    int: i64,
    num: f64,
    ptr: *const u8,
    len: usize,
}

extern "C" {
    fn wa_core_run(entry: *const c_char, elen: usize, argc: c_int, argv: *const *const c_char,
                   argl: *const usize, err: *mut *mut c_char, errlen: *mut usize) -> c_int;
    /// One work item against the instance's long-lived `lua_State` (see `glue.c`): `0` answered,
    /// `1` the item raised, `2` no such function, `3` the core could not boot.
    fn wa_core_call(name: *const c_char, nlen: usize, argc: c_int, argv: *const *const c_char,
                    argl: *const usize, out: *mut *mut c_char, outlen: *mut usize,
                    err: *mut *mut c_char, errlen: *mut usize) -> c_int;
    fn wa_core_reset();
    fn wa_core_free(p: *mut c_char);
    fn malloc(size: usize) -> *mut u8;
}

/// Results live here until glue.c has pushed them (it copies, lua_pushlstring), i.e. until the next call.
static mut RESULTS: Vec<Value> = Vec::new();
static mut SLOTS: Vec<Slot> = Vec::new();
/// The item a `next` handed over, kept alive until glue.c has pushed it.
static mut ITEM: Vec<u8> = Vec::new();

/// Turn the C argument array into the values the bridge carries.
unsafe fn values(argc: c_int, argv: *const Slot) -> Vec<Value> {
    let mut args = Vec::with_capacity(argc as usize);
    for slot in unsafe { std::slice::from_raw_parts(argv, argc as usize) } {
        args.push(match slot.kind {
            1 => Value::Boolean(slot.int != 0),
            2 => Value::Integer(slot.int),
            3 => Value::Number(slot.num),
            4 => Value::Bytes(unsafe { std::slice::from_raw_parts(slot.ptr, slot.len) }.to_vec()),
            6 => Value::Json(unsafe { std::slice::from_raw_parts(slot.ptr, slot.len) }.to_vec()),
            _ => Value::Nil,
        });
    }
    args
}

/// Lay `values` out in `SLOTS` and return how many Lua values they are (a string map spans 1 + 2n
/// slots). The caller reads `SLOTS.as_ptr()`; the bytes stay alive until the next call.
unsafe fn fill_results(values: Vec<Value>) -> c_int {
    unsafe {
        let results = &mut *std::ptr::addr_of_mut!(RESULTS);
        let slots = &mut *std::ptr::addr_of_mut!(SLOTS);
        *results = values;
        slots.clear();
        for value in results.iter() {
            let mut slot = Slot { kind: 0, int: 0, num: 0.0, ptr: std::ptr::null(), len: 0 };
            match value {
                Value::Nil => {},
                Value::Boolean(b) => { slot.kind = 1; slot.int = *b as i64; }
                Value::Integer(i) => { slot.kind = 2; slot.int = *i; }
                Value::Number(n) => { slot.kind = 3; slot.num = *n; }
                Value::Bytes(bytes) => { slot.kind = 4; slot.ptr = bytes.as_ptr(); slot.len = bytes.len(); }
                // The kernel never answers a call with a table this bridge cannot place: a table result
                // that is not a flat string map is refused there, where the reason is known.
                Value::Json(bytes) => { slot.kind = 6; slot.ptr = bytes.as_ptr(); slot.len = bytes.len(); }
                Value::StringMap(map) => {
                    slot.kind = 5;
                    slot.int = map.len() as i64;
                    slots.push(slot);
                    for (key, value) in map {
                        slots.push(Slot { kind: 4, int: 0, num: 0.0, ptr: key.as_ptr(), len: key.len() });
                        slots.push(Slot { kind: 4, int: 0, num: 0.0, ptr: value.as_ptr(), len: value.len() });
                    }
                    continue;
                }
            }
            slots.push(slot);
        }
        results.len() as c_int
    }
}

/// Copy an error text into a malloc'd buffer glue.c frees (it pushes the bytes, then frees).
unsafe fn write_error(message: String, out_err: *mut *mut u8, out_errlen: *mut usize) {
    unsafe {
        let buffer = malloc(message.len().max(1));
        std::ptr::copy_nonoverlapping(message.as_ptr(), buffer, message.len());
        *out_err = buffer;
        *out_errlen = message.len();
    }
}

/// Called by glue.c for every `host.<name>(...)`. Returns the number of results (>= 0) with
/// `*out` pointing at them, or -1 with `*out_err`/`*out_errlen` holding a malloc'd error text.
///
/// # Safety
/// `name`/`argv` must be the pointers glue.c built for this call, `argv` must hold `argc` slots, and
/// the out pointers must be valid to write. The result slots live until the next call on this thread.
#[no_mangle]
pub unsafe extern "C" fn rust_host_call(name: *const u8, nlen: usize, argc: c_int, argv: *const Slot,
                                        out: *mut *const Slot, out_err: *mut *mut u8, out_errlen: *mut usize) -> c_int {
    let name = String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(name, nlen) }).into_owned();
    let args = unsafe { values(argc, argv) };
    match call(&name, &args) {
        Ok(values) => {
            let n = unsafe { fill_results(values) };
            unsafe { *out = (&*std::ptr::addr_of!(SLOTS)).as_ptr() };
            n
        }
        Err(message) => {
            unsafe { write_error(message, out_err, out_errlen) };
            -1
        }
    }
}

/// Start a stream (`http_sse` today). Returns the handle, or -1 with an error text.
///
/// # Safety
/// Same contract as [`rust_host_call`]: glue.c's own pointers, its own out parameters.
#[no_mangle]
pub unsafe extern "C" fn rust_host_open(name: *const u8, nlen: usize, argc: c_int, argv: *const Slot,
                                        out_err: *mut *mut u8, out_errlen: *mut usize) -> i64 {
    let name = String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(name, nlen) }).into_owned();
    let args = unsafe { values(argc, argv) };
    match open(&name, &args) {
        Ok(handle) => handle as i64,
        Err(message) => {
            unsafe { write_error(message, out_err, out_errlen) };
            -1
        }
    }
}

/// The next item of a stream: `*has` 0 means the stream ended (ask `close` for the answer).
///
/// # Safety
/// `message`/`mlen` are glue.c's verdict message (unused when `verdict` is not 2); `out` and `has`
/// receive this call's item and whether there is one.
#[no_mangle]
pub unsafe extern "C" fn rust_host_next(handle: i64, verdict: c_int, message: *const u8, mlen: usize,
                                        out: *mut *const Slot, has: *mut c_int, out_err: *mut *mut u8,
                                        out_errlen: *mut usize) -> c_int {
    let decision = unsafe { decision_of(verdict, message, mlen) };
    match next(handle as u64, decision.as_ref()) {
        Ok(Some(item)) => {
            unsafe {
                let kept = &mut *std::ptr::addr_of_mut!(ITEM);
                *kept = item;
                let slots = &mut *std::ptr::addr_of_mut!(SLOTS);
                slots.clear();
                slots.push(Slot { kind: 4, int: 0, num: 0.0, ptr: kept.as_ptr(), len: kept.len() });
                *out = slots.as_ptr();
                *has = 1;
            }
            0
        }
        Ok(None) => {
            unsafe { *has = 0 };
            0
        }
        Err(message) => {
            unsafe { write_error(message, out_err, out_errlen) };
            -1
        }
    }
}

/// End a stream and take the capability's own answer: the same values a `call` would have returned.
///
/// # Safety
/// Same contract as [`rust_host_next`]; `count` receives how many values `*out` holds.
#[no_mangle]
pub unsafe extern "C" fn rust_host_close(handle: i64, verdict: c_int, message: *const u8, mlen: usize,
                                         out: *mut *const Slot, count: *mut c_int, out_err: *mut *mut u8,
                                         out_errlen: *mut usize) -> c_int {
    match close(handle as u64, &unsafe { verdict_of(verdict, message, mlen) }) {
        Ok(values) => {
            let n = unsafe { fill_results(values) };
            unsafe {
                *out = (&*std::ptr::addr_of!(SLOTS)).as_ptr();
                *count = n;
            }
            0
        }
        Err(message) => {
            unsafe { write_error(message, out_err, out_errlen) };
            -1
        }
    }
}

/// glue.c's verdict codes: -1 none (the first `next`), 0 continue, 1 stop, 2 fail with a message.
unsafe fn verdict_of(code: c_int, message: *const u8, mlen: usize) -> Verdict {
    match code {
        1 => Verdict::Stop,
        2 => Verdict::Fail(String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(message, mlen) }).into_owned()),
        _ => Verdict::Continue,
    }
}

/// The `option<verdict>` a `next` carries: `None` on the first call, where there is nothing to
/// decide about yet.
unsafe fn decision_of(code: c_int, message: *const u8, mlen: usize) -> Option<Verdict> {
    if code < 0 {
        None
    } else {
        Some(unsafe { verdict_of(code, message, mlen) })
    }
}

struct Core;

impl Guest for Core {
    fn run(entry: String, args: Vec<String>) -> Result<(), String> {
        let argv: Vec<*const c_char> = args.iter().map(|a| a.as_ptr() as *const c_char).collect();
        let argl: Vec<usize> = args.iter().map(|a| a.len()).collect();
        let mut err: *mut c_char = std::ptr::null_mut();
        let mut errlen = 0usize;
        let status = unsafe {
            wa_core_run(entry.as_ptr() as *const c_char, entry.len(), args.len() as c_int,
                        argv.as_ptr(), argl.as_ptr(), &mut err, &mut errlen)
        };
        if status == 0 {
            Ok(())
        } else {
            Err(unsafe { take_c_string(err, errlen) })
        }
    }

    /// The long-lived form: one `lua_State` per instance, booted by the first call.
    ///
    /// The error side keeps the four cases apart in the guest's own words, because the kernel maps
    /// them back to what a native call answers: `not-a-function:<name>`, `boot:<message>`, or the
    /// script's own error text.
    fn call(name: String, args: Vec<String>) -> Result<String, String> {
        let argv: Vec<*const c_char> = args.iter().map(|a| a.as_ptr() as *const c_char).collect();
        let argl: Vec<usize> = args.iter().map(|a| a.len()).collect();
        let mut out: *mut c_char = std::ptr::null_mut();
        let mut outlen = 0usize;
        let mut err: *mut c_char = std::ptr::null_mut();
        let mut errlen = 0usize;
        let status = unsafe {
            wa_core_call(name.as_ptr() as *const c_char, name.len(), args.len() as c_int,
                         argv.as_ptr(), argl.as_ptr(), &mut out, &mut outlen, &mut err, &mut errlen)
        };
        match status {
            0 => Ok(unsafe { take_c_string(out, outlen) }),
            2 => {
                unsafe { wa_core_free(err) };
                let missing = unsafe { take_c_string(out, outlen) };
                Err(format!("not-a-function:{missing}"))
            }
            3 => Err(format!("boot:{}", unsafe { take_c_string(err, errlen) })),
            _ => Err(unsafe { take_c_string(err, errlen) }),
        }
    }

    fn reset() {
        unsafe { wa_core_reset() }
    }
}

/// Copy a `malloc`'d buffer out of guest C and release it.
unsafe fn take_c_string(ptr: *mut c_char, len: usize) -> String {
    if ptr.is_null() {
        return String::new();
    }
    let text = String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(ptr as *const u8, len) }).into_owned();
    unsafe { wa_core_free(ptr) };
    text
}

export!(Core);
