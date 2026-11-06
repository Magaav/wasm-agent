//! `host.stt_*`: the node half of queue phase 2 for speech (`rust/wa-stt-remote`,
//! `rust/wa-kernel-runtime/src/stt_node.rs`), reached from Lua.
//!
//! Five functions, one per thing the Lua side must be able to do:
//!
//! | capability | who calls it | what it is |
//! | --- | --- | --- |
//! | `stt_call` | `server.lua#node_capability`, capability `stt` | one admitted call from a peer node: the producing node's queue |
//! | `stt_submit` | an operator/tool (and the test harness) | enqueue a note with its real chat/message ids and send time |
//! | `stt_admin` | `services.lua` action `stt`, `stt.lua` on boot | configure the role; the operator view; one job's state; a sweep |
//! | `stt_pending` / `stt_deliver` | `stt.lua`'s tick | the pump: the worker thread hands Lua one envelope at a time, Lua signs and sends it with `nodes.lua`, and hands the answer back |
//!
//! The pump is why the worker's decision logic is not re-written in Lua: `stt_node` runs the
//! library's `RemoteWorker::poll_once` on a thread and only asks Lua for the transport, because the
//! node's private key lives in the interpreter's `host.sign` and nowhere else.
//!
//! Every answer is a table; nothing here can carry audio or transcript text outward (`stt_call`
//! returns the wire bodies, which are the peer's own, and `stt_admin` reports ids and counts).

use serde_json::Value;
use wa_host_support::lua::{arg_integer, arg_string, lua_pushlstring, LuaState};
use wa_kernel_runtime::stt_node;

fn push(l: *mut LuaState, value: &Value) -> std::os::raw::c_int {
    wa_host_support::json::push_json(l, value);
    1
}

/// `host.stt_call(envelope_json, caller_node_id)` — one peer call. The caller id is what
/// `wa_node_call` verified, so the envelope cannot claim to be another node.
pub extern "C-unwind" fn call(l: *mut LuaState) -> std::os::raw::c_int {
    let envelope = arg_string(l, 1).unwrap_or_default();
    let caller = arg_string(l, 2).unwrap_or_default();
    let answer = stt_node::call(&envelope, &caller);
    let bytes = answer.as_bytes();
    unsafe { lua_pushlstring(l, bytes.as_ptr() as *const std::os::raw::c_char, bytes.len()) };
    1
}

/// `host.stt_submit(request_json)` — `{audio_b64, mime, language, chat, msg, account, generation,
/// sent_at_ms?}`. The answer names the job id or the refusal; it never echoes the request.
pub extern "C-unwind" fn submit(l: *mut LuaState) -> std::os::raw::c_int {
    let raw = arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => stt_node::submit(&request),
        Err(_) => serde_json::json!({"refused": "malformed:request"}),
    };
    push(l, &answer)
}

/// `host.stt_admin(request_json)` — `configure`, `status`, `job`, `sweep` or `submit`.
pub extern "C-unwind" fn admin(l: *mut LuaState) -> std::os::raw::c_int {
    let raw = arg_string(l, 1).unwrap_or_default();
    let answer = match serde_json::from_str::<Value>(&raw) {
        Ok(request) => stt_node::admin(&request),
        Err(_) => serde_json::json!({"refused": "malformed:request"}),
    };
    push(l, &answer)
}

/// `host.stt_pending()` — the next call the worker thread wants signed, or `null`.
pub extern "C-unwind" fn pending(l: *mut LuaState) -> std::os::raw::c_int {
    push(l, &stt_node::pending())
}

/// `host.stt_deliver(id, reply_json)` — the peer's answer, and the next pending call (or `null`), so
/// one tick drains the whole sequence.
pub extern "C-unwind" fn deliver(l: *mut LuaState) -> std::os::raw::c_int {
    let id = arg_integer(l, 1).unwrap_or(0).max(0) as u64;
    let reply = arg_string(l, 2).unwrap_or_default();
    push(l, &stt_node::deliver(id, &reply))
}
