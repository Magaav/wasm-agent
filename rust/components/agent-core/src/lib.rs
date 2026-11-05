//! agent-core: the Lua core inside a wasm32-wasip2 component (docs/KERNEL.md, "A2.1").
//!
//! glue.c owns the interpreter; this file only crosses the component boundary: `rust_host_call`
//! turns the C-side argument array into `wa:kernel/host` values and back, and `run` is the export.
use std::ffi::{c_char, c_int};

wit_bindgen::generate!({ world: "core-component", path: "../../../wit/kernel" });

use wa::kernel::host::{call, Value};

/// One argument or result as glue.c lays it out. `kind`: 0 nil, 1 boolean (`int` 0/1),
/// 2 integer, 3 number, 4 bytes (`ptr`, `len`), 5 string map (`int` entries follow as key/value
/// byte slots, results only).
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
    fn malloc(size: usize) -> *mut u8;
}

/// Results live here until glue.c has pushed them (it copies, lua_pushlstring), i.e. until the next call.
static mut RESULTS: Vec<Value> = Vec::new();
static mut SLOTS: Vec<Slot> = Vec::new();

/// Called by glue.c for every `host.<name>(...)`. Returns the number of results (>= 0) with
/// `*out` pointing at them, or -1 with `*out_err`/`*out_errlen` holding a malloc'd error text.
#[no_mangle]
pub unsafe extern "C" fn rust_host_call(name: *const u8, nlen: usize, argc: c_int, argv: *const Slot,
                                        out: *mut *const Slot, out_err: *mut *mut u8, out_errlen: *mut usize) -> c_int {
    let name = String::from_utf8_lossy(std::slice::from_raw_parts(name, nlen)).into_owned();
    let mut args = Vec::with_capacity(argc as usize);
    for slot in std::slice::from_raw_parts(argv, argc as usize) {
        args.push(match slot.kind {
            1 => Value::Boolean(slot.int != 0),
            2 => Value::Integer(slot.int),
            3 => Value::Number(slot.num),
            4 => Value::Bytes(std::slice::from_raw_parts(slot.ptr, slot.len).to_vec()),
            _ => Value::Nil,
        });
    }
    match call(&name, &args) {
        Ok(values) => {
            let results = &mut *std::ptr::addr_of_mut!(RESULTS);
            let slots = &mut *std::ptr::addr_of_mut!(SLOTS);
            *results = values;
            slots.clear();
            for value in results.iter() {
                let mut slot = Slot { kind: 0, int: 0, num: 0.0, ptr: std::ptr::null(), len: 0 };
                match value {
                    Value::Nil => {}
                    Value::Boolean(b) => { slot.kind = 1; slot.int = *b as i64; }
                    Value::Integer(i) => { slot.kind = 2; slot.int = *i; }
                    Value::Number(n) => { slot.kind = 3; slot.num = *n; }
                    Value::Bytes(bytes) => { slot.kind = 4; slot.ptr = bytes.as_ptr(); slot.len = bytes.len(); }
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
            *out = slots.as_ptr();
            // the count of Lua values, not of slots (a string map spans 1 + 2n slots)
            results.len() as c_int
        }
        Err(message) => {
            let buffer = malloc(message.len().max(1));
            std::ptr::copy_nonoverlapping(message.as_ptr(), buffer, message.len());
            *out_err = buffer;
            *out_errlen = message.len();
            -1
        }
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
            let text = unsafe { std::slice::from_raw_parts(err as *const u8, errlen) };
            Err(String::from_utf8_lossy(text).into_owned())
        }
    }
}

export!(Core);
