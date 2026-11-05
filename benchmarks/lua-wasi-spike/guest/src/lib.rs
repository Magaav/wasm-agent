//! Guest: runs Lua chunks; every host.<name>(args...) from Lua becomes one WIT call
//! `host-call.call(name, args)`. Args/results are strings (lossy UTF-8 for this spike).
wit_bindgen::generate!({ world: "lua-core", path: "../wit" });

use std::ffi::{c_char, c_int, c_void, CString};

extern "C" {
    fn wa_lua_run(src: *const u8, len: usize, chunk: *const c_char, out: *mut *mut u8, outlen: *mut usize) -> c_int;
    fn malloc(n: usize) -> *mut c_void;
    fn free(p: *mut c_void);
}

unsafe fn to_c(bytes: &[u8], out: *mut *mut u8, outlen: *mut usize) {
    let p = malloc(bytes.len().max(1)) as *mut u8;
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), p, bytes.len());
    *out = p;
    *outlen = bytes.len();
}

#[no_mangle]
pub unsafe extern "C" fn rust_host_call(name: *const u8, nlen: usize, argc: c_int, argv: *const *const u8, argl: *const usize, out: *mut *mut u8, outlen: *mut usize) -> c_int {
    let name = String::from_utf8_lossy(std::slice::from_raw_parts(name, nlen)).into_owned();
    let args: Vec<String> = (0..argc as usize)
        .map(|i| String::from_utf8_lossy(std::slice::from_raw_parts(*argv.add(i), *argl.add(i))).into_owned())
        .collect();
    match wa::spike::host_call::call(&name, &args) {
        Ok(results) => {
            let mut buf = (results.len() as u32).to_le_bytes().to_vec();
            for r in &results {
                buf.extend((r.len() as u32).to_le_bytes());
                buf.extend(r.as_bytes());
            }
            to_c(&buf, out, outlen);
            0
        }
        Err(error) => {
            to_c(error.as_bytes(), out, outlen);
            1
        }
    }
}

struct LuaComponent;
export!(LuaComponent);

impl Guest for LuaComponent {
    fn run(source: String, chunk_name: String) -> Result<String, String> {
        let chunk = CString::new(format!("={chunk_name}")).unwrap_or_default();
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut outlen = 0usize;
        let rc = unsafe { wa_lua_run(source.as_ptr(), source.len(), chunk.as_ptr(), &mut out, &mut outlen) };
        let text = unsafe { String::from_utf8_lossy(std::slice::from_raw_parts(out, outlen)).into_owned() };
        unsafe { free(out as *mut c_void) };
        if rc == 0 { Ok(text) } else { Err(text) }
    }
}
