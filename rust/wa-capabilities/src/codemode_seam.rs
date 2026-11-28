//! Code mode's component seam - and what is left of it in the host.
//!
//! WHAT MOVED, AND WHY. This file used to be a 724-line wasmtime embedding: an `Engine`, a compiled-component
//! cache, a `WasiView`, a live-session table and `impl wa:kernel/quickjs::Host for Host` - the host side of the
//! sandbox interface. Every other component in the node runs through the kernel (`wa-kernel-runtime`), but
//! codemode could not: its world imports `wa:kernel/quickjs`, and the only implementation of that interface was
//! here, in the host crate. So the kernel learned to host such a component (28/11, row 20):
//! `wa_kernel_runtime::sandbox_host` is the embedding, moved, and it asks back for the sandbox through
//! [`wa_kernel_runtime::sandbox_host::set_sandbox`].
//!
//! WHAT THE HOST STILL OWNS: the sandbox itself - `crate::quickjs`, the checksum-pinned QuickJS reactor - and
//! the answer to "what is installed here". That is the callback this module installs. Nothing about hosting,
//! deadlines, engine caching or traps is decided below this line.
//!
//! The public surface is unchanged (`available`, `call`, `call_with`, `Config`, `Sandbox`, `capability`), so
//! every caller and every row reads the same names it did.
pub use wa_kernel_runtime::sandbox_host::{Config, Sandbox, COMPONENT};

/// Install the node's own sandbox as the one the kernel's codemode host asks. Idempotent: the first install
/// wins, which is what a process with one QuickJS reactor wants.
pub fn install() {
    wa_kernel_runtime::sandbox_host::set_sandbox(Box::new(|action, args| match crate::quickjs::control(action, args) {
        Ok(answer) => answer,
        Err(error) => serde_json::json!({"ok": false, "error": format!("codemode_sandbox: {error:#}")}),
    }));
}

/// `available()` after installing the sandbox: the answer is the same, and the sandbox is there for the run
/// that follows it.
pub fn ensure() {
    install();
}

/// `host.codemode(request_json)` -> the answer from [`call`]. The install happens here because this is the
/// first door every call comes through: a process that never asks code mode never installs a sandbox.
pub extern "C-unwind" fn capability(l: *mut wa_host_support::lua::LuaState) -> std::os::raw::c_int {
    install();
    wa_kernel_runtime::sandbox_host::capability(l)
}

/// One code-mode call, with the node's sandbox installed.
pub fn call(request: &serde_json::Value) -> serde_json::Value {
    install();
    wa_kernel_runtime::sandbox_host::call(request)
}

pub fn call_with(config: &Config, request: &serde_json::Value) -> serde_json::Value {
    install();
    wa_kernel_runtime::sandbox_host::call_with(config, request)
}

pub fn available() -> Result<String, String> {
    install();
    wa_kernel_runtime::sandbox_host::available()
}
