//! `host.fabric_*`: the compute fabric reached from Lua (`rust/wa-fabric`,
//! `rust/wa-kernel-runtime/src/fabric_node.rs`, `docs/FABRIC.md`).
//!
//! Four functions, one per thing the Lua side must be able to do:
//!
//! | capability | who calls it | what it is |
//! | --- | --- | --- |
//! | `fabric_admin` | `services.lua` action `fabric`, a `fabric.lua` tick | configure the node's fabric; the operator view; one housekeeping tick |
//! | `fabric_call` | `server.lua#node_capability`, capability `fabric` | one admitted call from a peer: its heartbeat, or an offer it wants answered |
//! | `fabric_pending` / `fabric_deliver` | the node's tick | the pump: the fabric hands Lua one record at a time, Lua signs and sends it with `nodes.lua`, and hands the answer back |
//!
//! The pump exists for the same reason the speech queue has one: the node's private key lives in the
//! interpreter's `host.sign` and nowhere else, so the fabric's thread decides *what* to say and Lua
//! decides *how to sign it*. Nothing here can carry a payload: an offer names a job id, a heartbeat
//! carries load and capabilities, and the admin view reports ids, numbers and words.

use serde_json::Value;
use wa_host_support::lua::{arg_integer, arg_string, lua_pushlstring, LuaState};
use wa_kernel_runtime::fabric_node;

fn push(l: *mut LuaState, value: &Value) -> std::os::raw::c_int {
    wa_host_support::json::push_json(l, value);
    1
}

/// `host.fabric_admin(request_json)` — `configure`, `status`, `tick`, `submit`, `take`, `settle`.
pub extern "C-unwind" fn admin(l: *mut LuaState) -> std::os::raw::c_int {
    let raw = arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => match request.get("action").and_then(Value::as_str).unwrap_or("status") {
            "configure" => fabric_node::configure(&request),
            "tick" => fabric_node::tick(),
            "submit" => fabric_node::submit(&request),
            "take" => fabric_node::take(&request),
            "settle" => fabric_node::settle(&request),
            "status" => fabric_node::admin(&request),
            _ => serde_json::json!({"ok": false, "error": "invalid_fabric_action"}),
        },
        Err(_) => serde_json::json!({"ok": false, "error": "invalid_fabric_request"}),
    };
    push(l, &answer)
}

/// `host.fabric_call(body_json, caller_node_id)` — one peer call. The caller id is the one the
/// transport verified, so a body cannot claim to be another node.
pub extern "C-unwind" fn call(l: *mut LuaState) -> std::os::raw::c_int {
    let body = arg_string(l, 1).unwrap_or_default();
    let caller = arg_string(l, 2).unwrap_or_default();
    let answer = fabric_node::call(&body, &caller);
    let bytes = answer.to_string();
    unsafe { lua_pushlstring(l, bytes.as_ptr() as *const std::os::raw::c_char, bytes.len()) };
    1
}

/// `host.fabric_pending()` — the next record the pump must sign and send, or `null`.
pub extern "C-unwind" fn pending(l: *mut LuaState) -> std::os::raw::c_int {
    push(l, &fabric_node::pending())
}

/// `host.fabric_deliver(id, reply_json)` — the peer's answer, and the next record to send (or
/// `null`), so one tick drains the whole sequence.
pub extern "C-unwind" fn deliver(l: *mut LuaState) -> std::os::raw::c_int {
    let id = arg_integer(l, 1).unwrap_or(0).max(0) as u64;
    let reply = arg_string(l, 2).unwrap_or_default();
    push(l, &fabric_node::deliver(id, &reply))
}
