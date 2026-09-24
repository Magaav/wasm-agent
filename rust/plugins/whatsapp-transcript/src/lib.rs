//! Pure reply formatter. Audio retrieval, speech recognition, and WhatsApp sends
//! stay with the host; this plugin receives only the recognized text.
use std::{mem, slice};

fn reply(value: serde_json::Value) -> i64 {
    let bytes = value.to_string().into_bytes();
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
pub extern "C" fn describe() -> i64 {
    reply(serde_json::json!({
        "name": "whatsapp_transcript",
        "surface": "internal",
        "description": "Format a locally recognized WhatsApp voice message for its source chat.",
        "parameters": {"type":"object","properties":{"transcript":{"type":"string"}},"required":["transcript"]}
    }))
}

#[no_mangle]
pub extern "C" fn call(pointer: i32, length: i32) -> i64 {
    if pointer < 0 || length < 0 || length > 20_000 {
        return reply(serde_json::json!({"error":"invalid_input_length"}));
    }
    let input = unsafe { slice::from_raw_parts(pointer as *const u8, length as usize) };
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(input) else {
        return reply(serde_json::json!({"error":"invalid_json"}));
    };
    let Some(transcript) = value.get("transcript").and_then(|x| x.as_str()) else {
        return reply(serde_json::json!({"error":"transcript_required"}));
    };
    let cleaned: String = transcript.chars()
        .filter(|ch| !ch.is_control() || *ch == '\n')
        .collect();
    let cleaned = cleaned.trim();
    if cleaned.is_empty() {
        return reply(serde_json::json!({"error":"empty_transcript"}));
    }
    if cleaned.chars().count() > 12_000 {
        return reply(serde_json::json!({"error":"transcript_too_long"}));
    }
    let mut parts: Vec<String> = Vec::new();
    let mut chunk = String::new();
    let mut chunk_chars = 0usize;
    for ch in cleaned.chars() {
        chunk.push(ch);
        chunk_chars += 1;
        if chunk_chars == 3_300 {
            parts.push(mem::take(&mut chunk));
            chunk_chars = 0;
        }
    }
    if !chunk.is_empty() { parts.push(chunk); }
    let count = parts.len();
    let bodies: Vec<String> = parts.into_iter().enumerate().map(|(index, part)| {
        if count == 1 {
            format!("🎙️ _Copiloto-Transcritor_\n{part}")
        } else {
            format!("🎙️ _Copiloto-Transcritor_ ({}/{}):\n{part}", index + 1, count)
        }
    }).collect();
    reply(serde_json::json!({"bodies": bodies}))
}
