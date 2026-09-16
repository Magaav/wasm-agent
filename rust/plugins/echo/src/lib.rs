//! Example wasm-agent tool plugin.
//!
//! A plugin is a core WASM module exporting a tiny ABI: `alloc`, `describe`
//! and `call`, plus its linear `memory`. It needs no imports and no runtime.
use std::mem;
use std::slice;

/// Hand a JSON string to the host: packed `ptr << 32 | len`.
fn return_string(value: String) -> i64 {
    let bytes = value.into_bytes();
    let length = bytes.len() as i64;
    let pointer = bytes.as_ptr() as i64;
    mem::forget(bytes);
    (pointer << 32) | (length & 0xffff_ffff)
}

/// Guest allocation for the host to write tool arguments into.
#[no_mangle]
pub extern "C" fn alloc(length: i32) -> i32 {
    let mut buffer = Vec::<u8>::with_capacity(length.max(0) as usize);
    let pointer = buffer.as_mut_ptr() as i32;
    mem::forget(buffer);
    pointer
}

/// Declare this tool to the agent.
#[no_mangle]
pub extern "C" fn describe() -> i64 {
    return_string(
        r#"{"name":"echo","description":"Echo the given text back to the caller.","parameters":{"type":"object","properties":{"text":{"type":"string","description":"Text to echo."}},"required":["text"]}}"#
            .to_string(),
    )
}

/// Invoke this tool with a JSON argument object.
#[no_mangle]
pub extern "C" fn call(pointer: i32, length: i32) -> i64 {
    let input = unsafe { slice::from_raw_parts(pointer as *const u8, length.max(0) as usize) };
    let text = String::from_utf8_lossy(input);
    let parsed: serde_json::Value = serde_json::from_str(&text).unwrap_or(serde_json::json!({}));
    let echoed = parsed.get("text").and_then(|value| value.as_str()).unwrap_or("");
    return_string(serde_json::json!({ "echo": echoed }).to_string())
}
