//! The one answer shape the capability functions share: a JSON value pushed as a Lua string.
//!
//! Moved verbatim from `wa-host/src/host.rs` (`push_json`). It lives here because the kernel's
//! entry points (`components`, `service`, `state`) and the host's capability functions all answer
//! through it, and the kernel may not import the host crate.
use crate::lua::{lua_pushlstring, LuaState};
use serde_json::Value;
use std::os::raw::c_char;

pub fn push_json(l: *mut LuaState, value: &Value) {
    let text = serde_json::to_string(value).unwrap_or_else(|_| "null".to_string());
    unsafe { lua_pushlstring(l, text.as_ptr() as *const c_char, text.len()) };
}
