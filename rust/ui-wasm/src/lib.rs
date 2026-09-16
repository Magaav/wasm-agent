//! UI renderer compiled to WASM.
//!
//! Turns an assistant reply into safe HTML: escapes the text first, then applies
//! `**bold**` and `` `code` `` and converts newlines. The web UI loads this and
//! uses it to render messages, so HTML safety lives in one audited WASM module.
use std::mem;
use std::slice;

fn packed(value: String) -> i64 {
    let bytes = value.into_bytes();
    let length = bytes.len() as i64;
    let pointer = bytes.as_ptr() as i64;
    mem::forget(bytes);
    (pointer << 32) | (length & 0xffff_ffff)
}

#[no_mangle]
pub extern "C" fn alloc(length: i32) -> i32 {
    let mut buffer = Vec::<u8>::with_capacity(length.max(0) as usize);
    let pointer = buffer.as_mut_ptr() as i32;
    mem::forget(buffer);
    pointer
}

#[no_mangle]
pub extern "C" fn render(pointer: i32, length: i32) -> i64 {
    let input = unsafe { slice::from_raw_parts(pointer as *const u8, length.max(0) as usize) };
    packed(render_markdown(&String::from_utf8_lossy(input)))
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn render_inline(line: &str) -> String {
    let escaped = escape(line);
    let mut out = String::new();
    let mut chars = escaped.chars().peekable();
    let mut in_code = false;
    let mut in_bold = false;
    while let Some(c) = chars.next() {
        if c == '`' {
            in_code = !in_code;
            out.push_str(if in_code { "<code>" } else { "</code>" });
        } else if c == '*' && chars.peek() == Some(&'*') {
            chars.next();
            in_bold = !in_bold;
            out.push_str(if in_bold { "<strong>" } else { "</strong>" });
        } else {
            out.push(c);
        }
    }
    out
}

fn render_markdown(input: &str) -> String {
    let mut out = String::new();
    for (index, line) in input.split('\n').enumerate() {
        if index > 0 {
            out.push_str("<br>");
        }
        out.push_str(&render_inline(line));
    }
    out
}
