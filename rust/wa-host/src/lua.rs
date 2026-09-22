//! Minimal safe-ish bindings to the Lua 5.4 C API.
//!
//! We vendor Lua (see `vendor/lua`) and link it statically, so the whole agent
//! is one Rust binary with Lua inside: no Python, no interpreter dependency.
#![allow(non_camel_case_types)]

use std::ffi::{c_char, c_int, c_void, CStr, CString};

pub type LuaState = c_void;
pub type LuaCFunction = extern "C" fn(*mut LuaState) -> c_int;
pub type LuaInteger = i64;
pub type LuaNumber = f64;

pub const LUA_OK: c_int = 0;
pub const LUA_MULTRET: c_int = -1;
pub const LUA_REGISTRYINDEX: c_int = -1001000;

pub const LUA_TNIL: c_int = 0;
pub const LUA_TBOOLEAN: c_int = 1;
pub const LUA_TNUMBER: c_int = 3;
pub const LUA_TSTRING: c_int = 4;
pub const LUA_TTABLE: c_int = 5;

/// Index of the i-th upvalue of a running C closure.
pub fn upvalue_index(i: c_int) -> c_int {
    LUA_REGISTRYINDEX - i
}

extern "C" {
    pub fn luaL_newstate() -> *mut LuaState;
    pub fn luaL_openlibs(l: *mut LuaState);
    pub fn lua_close(l: *mut LuaState);

    pub fn luaL_loadbufferx(
        l: *mut LuaState,
        buff: *const c_char,
        sz: usize,
        name: *const c_char,
        mode: *const c_char,
    ) -> c_int;
    pub fn lua_pcallk(
        l: *mut LuaState,
        nargs: c_int,
        nresults: c_int,
        errfunc: c_int,
        ctx: isize,
        k: *mut c_void,
    ) -> c_int;

    pub fn lua_gettop(l: *mut LuaState) -> c_int;
    pub fn lua_settop(l: *mut LuaState, idx: c_int);
    pub fn lua_pushvalue(l: *mut LuaState, idx: c_int);
    pub fn lua_pushnil(l: *mut LuaState);
    pub fn lua_pushboolean(l: *mut LuaState, b: c_int);
    pub fn lua_pushinteger(l: *mut LuaState, n: LuaInteger);
    pub fn lua_pushnumber(l: *mut LuaState, n: LuaNumber);
    pub fn lua_pushlstring(l: *mut LuaState, s: *const c_char, len: usize) -> *const c_char;
    pub fn lua_pushcclosure(l: *mut LuaState, f: LuaCFunction, n: c_int);
    pub fn lua_pushlightuserdata(l: *mut LuaState, p: *mut c_void);

    pub fn lua_createtable(l: *mut LuaState, narr: c_int, nrec: c_int);
    pub fn lua_setfield(l: *mut LuaState, idx: c_int, k: *const c_char);
    pub fn lua_getfield(l: *mut LuaState, idx: c_int, k: *const c_char);
    pub fn lua_rawseti(l: *mut LuaState, idx: c_int, n: LuaInteger);
    pub fn lua_rawgeti(l: *mut LuaState, idx: c_int, n: LuaInteger) -> c_int;
    pub fn lua_rawlen(l: *mut LuaState, idx: c_int) -> usize;
    pub fn lua_next(l: *mut LuaState, idx: c_int) -> c_int;
    pub fn lua_remove(l: *mut LuaState, idx: c_int);
    pub fn lua_setglobal(l: *mut LuaState, name: *const c_char);
    pub fn lua_getglobal(l: *mut LuaState, name: *const c_char) -> c_int;

    pub fn lua_tolstring(l: *mut LuaState, idx: c_int, len: *mut usize) -> *const c_char;
    pub fn lua_tointegerx(l: *mut LuaState, idx: c_int, isnum: *mut c_int) -> LuaInteger;
    pub fn lua_tonumberx(l: *mut LuaState, idx: c_int, isnum: *mut c_int) -> LuaNumber;
    pub fn lua_toboolean(l: *mut LuaState, idx: c_int) -> c_int;
    pub fn lua_touserdata(l: *mut LuaState, idx: c_int) -> *mut c_void;
    pub fn lua_type(l: *mut LuaState, idx: c_int) -> c_int;
    pub fn lua_error(l: *mut LuaState) -> c_int;
}

pub fn cstr(s: &str) -> CString {
    CString::new(s).expect("no interior nul")
}

// SAFETY: the interpreter is used by exactly one thread. `serve` moves it into
// the agent thread at startup and nothing else touches it afterwards; every path
// that reaches Lua in process (the accept thread answers static requests and
// forwards the rest) goes through that one thread. This is what keeps the
// "single-threaded" invariant while letting the node answer its own UI during a
// running run.
unsafe impl Send for Lua {}

pub struct Lua {
    pub l: *mut LuaState,
    /// A value the interpreter owns and drops with itself. The per-interpreter
    /// `Host` (its own SQLite connection) is stored here so it is freed exactly
    /// when the interpreter is, with no leaked box and no connection outliving
    /// the Lua that used it. The host functions hold a pointer into it; moving the
    /// `Box` does not move the allocation, so the pointer stays valid.
    owned: Option<Box<dyn std::any::Any + Send>>,
}

impl Lua {
    pub fn new() -> Self {
        unsafe {
            let l = luaL_newstate();
            assert!(!l.is_null(), "luaL_newstate failed");
            luaL_openlibs(l);
            Lua { l, owned: None }
        }
    }

    /// Attach a value whose lifetime is the interpreter's.
    pub fn own(&mut self, value: Box<dyn std::any::Any + Send>) {
        self.owned = Some(value);
    }

    /// Roll back any transaction this interpreter's own connection left open.
    ///
    /// A Lua error can abandon a `BEGIN` that no later statement closes; on a
    /// persistent worker that transaction would hold the write lock until the
    /// process exits, stalling every other interpreter. The caller invokes this
    /// when a Lua call returned an error, so the failure cannot outlive the request.
    pub fn rollback_if_open(&self) {
        let Some(owned) = self.owned.as_ref() else { return };
        let Some(host) = owned.downcast_ref::<crate::host::Host>() else { return };
        if let Ok(connection) = host.db.lock() {
            if !connection.is_autocommit() {
                let _ = connection.execute_batch("ROLLBACK");
            }
        }
    }

    /// Run a chunk of Lua source, returning an error string on failure.
    pub fn do_string(&self, code: &str, name: &str) -> Result<(), String> {
        let name = cstr(name);
        unsafe {
            if luaL_loadbufferx(
                self.l,
                code.as_ptr() as *const c_char,
                code.len(),
                name.as_ptr(),
                std::ptr::null(),
            ) != LUA_OK
            {
                return Err(self.take_error());
            }
            if lua_pcallk(self.l, 0, LUA_MULTRET, 0, 0, std::ptr::null_mut()) != LUA_OK {
                return Err(self.take_error());
            }
        }
        Ok(())
    }

    /// Call a global function with JSON-encoded arguments; returns its Lua
    /// string result (or an error string).
    pub fn call_string(&self, function: &str, args: &[&str]) -> Result<String, String> {
        unsafe {
            lua_getglobal(self.l, cstr(function).as_ptr());
            if lua_type(self.l, -1) != 6 {
                // LUA_TFUNCTION
                lua_settop(self.l, -2);
                return Err(format!("{function} is not a function"));
            }
            for arg in args {
                lua_pushlstring(self.l, arg.as_ptr() as *const c_char, arg.len());
            }
            if lua_pcallk(self.l, args.len() as c_int, 1, 0, 0, std::ptr::null_mut()) != LUA_OK {
                return Err(self.take_error());
            }
            let result = self.to_string(-1).unwrap_or_default();
            lua_settop(self.l, -2);
            Ok(result)
        }
    }

    pub fn push_table(&self) {
        unsafe { lua_createtable(self.l, 0, 16) }
    }

    pub fn set_global(&self, name: &str) {
        unsafe { lua_setglobal(self.l, cstr(name).as_ptr()) }
    }

    /// Pop the top `n` stack slots.
    pub fn pop(&self, n: c_int) {
        unsafe { lua_settop(self.l, -n - 1) }
    }

    /// Register a C function (no upvalue) into the table on top of the stack.
    pub fn register(&self, name: &str, f: LuaCFunction) {
        unsafe {
            lua_pushcclosure(self.l, f, 0);
            lua_setfield(self.l, -2, cstr(name).as_ptr());
        }
    }

    /// Register a C function with a lightuserdata upvalue into the top table.
    pub fn register_with_upvalue(&self, name: &str, f: LuaCFunction, data: *mut c_void) {
        unsafe {
            lua_pushlightuserdata(self.l, data);
            lua_pushcclosure(self.l, f, 1);
            lua_setfield(self.l, -2, cstr(name).as_ptr());
        }
    }

    /// Set the value on top of the stack into the table at `idx`.
    pub fn set_field(&self, idx: c_int, key: &str) {
        unsafe { lua_setfield(self.l, idx, cstr(key).as_ptr()) }
    }

    /// Set the top value into the table at -2 at integer key `n`.
    pub fn raw_seti(&self, n: c_int) {
        unsafe { lua_rawseti(self.l, -2, n as LuaInteger) }
    }

    pub fn push_number(&self, n: f64) {
        unsafe { lua_pushnumber(self.l, n) }
    }

    pub fn push_string(&self, s: &str) {
        unsafe {
            lua_pushlstring(self.l, s.as_ptr() as *const c_char, s.len());
        }
    }

    pub fn push_bool(&self, b: bool) {
        unsafe { lua_pushboolean(self.l, if b { 1 } else { 0 }) }
    }

    /// Read a Lua string as Rust text.
    ///
    /// Lua strings are byte strings, and this is where they become UTF-8 - so it has to *decode*
    /// them. It used to widen each byte to a character (`.map(|b| b as char)`), which is Latin-1:
    /// an em dash is three UTF-8 bytes, so it came out as three characters - `â` followed by two
    /// invisible control codes, which is exactly what a chat bubble showed.
    ///
    /// This is the reader for a Lua call's *return value*, so every JSON response body went through
    /// it and every non-ASCII character in one was mangled: the transcript you load is corrupted
    /// while the live stream is not, because `arg_string` (used for arguments, including the SSE
    /// line) was always correct. The data was never lost - only its trip out.
    pub fn to_string(&self, idx: c_int) -> Option<String> {
        unsafe {
            let mut len = 0usize;
            let ptr = lua_tolstring(self.l, idx, &mut len);
            if ptr.is_null() {
                return None;
            }
            let bytes = std::slice::from_raw_parts(ptr as *const u8, len);
            // Lossy rather than strict: a Lua string can legitimately hold arbitrary bytes (a
            // screenshot's base64, a truncated file), and refusing the whole value over one bad
            // byte would break a response rather than show it.
            Some(String::from_utf8_lossy(bytes).into_owned())
        }
    }

    fn take_error(&self) -> String {
        unsafe {
            let message = self.to_string(-1).unwrap_or_else(|| "unknown lua error".into());
            lua_settop(self.l, -2);
            message
        }
    }
}

impl Default for Lua {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for Lua {
    fn drop(&mut self) {
        // Close the interpreter first, then drop what it owned (its SQLite
        // connection), which rolls back any transaction it left open.
        unsafe { lua_close(self.l) }
    }
}

/// Read a C string at `idx` (returns None for non-strings).
pub fn arg_string(l: *mut LuaState, idx: c_int) -> Option<String> {
    unsafe {
        let mut len = 0usize;
        let ptr = lua_tolstring(l, idx, &mut len);
        if ptr.is_null() {
            None
        } else {
            Some(CStr::from_ptr(ptr).to_string_lossy().to_string())
        }
    }
}

/// Read an integer at `idx` (None for missing values or non-numbers).
pub fn arg_integer(l: *mut LuaState, idx: c_int) -> Option<i64> {
    unsafe {
        let mut isnum: c_int = 0;
        let value = lua_tointegerx(l, idx, &mut isnum);
        if isnum == 0 {
            None
        } else {
            Some(value)
        }
    }
}
