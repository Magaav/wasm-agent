//! The WhatsApp archive as a component: one JSON question per call over `wa:archive`'s `control`, the same
//! door shape the codemode component serves (`rust/components/codemode`).
//!
//! EVERY ANSWER IS THE LIBRARY'S: `rust/wa-whatsapp-archive` decides which month is due, which are restored,
//! what a file is called and when it expires. What this crate adds is the two IMPORTS those operations need -
//! the store an index lives behind and the keystore's seal/open - bridged to the `Kv` and `Sealer` traits the
//! library already took as arguments. A host answers them through a callback; nothing here decides anything.
use serde_json::{json, Value};
use wa_whatsapp_archive as archive;

wit_bindgen::generate!({ path: "../../../wit/archive", world: "archive-component", generate_all });

/// The imported store, as the library's `Kv`.
struct Store;

impl archive::Kv for Store {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, String> {
        wa::archive::store::get(key)
    }

    fn set(&self, key: &[u8], value: &[u8]) -> Result<(), String> {
        wa::archive::store::set(key, value)
    }

    fn del(&self, key: &[u8]) -> Result<(), String> {
        wa::archive::store::del(key)
    }

    fn scan(&self, prefix: &[u8], cursor: Option<Vec<u8>>, limit: usize) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
        wa::archive::store::scan(prefix, cursor.as_deref(), limit as u32)
    }
}

/// The imported keystore, as the library's `Sealer`.
struct Keys;

impl archive::Sealer for Keys {
    fn seal(&self, context: &str, plaintext: &[u8]) -> Result<Vec<u8>, String> {
        wa::archive::sealer::seal(context, plaintext)
    }

    fn open(&self, context: &str, sealed: &[u8]) -> Result<Vec<u8>, String> {
        wa::archive::sealer::open(context, sealed)
    }
}

fn number(args: &Value, key: &str) -> i64 {
    args.get(key).and_then(Value::as_i64).unwrap_or_default()
}

fn text(args: &Value, key: &str) -> String {
    args.get(key).and_then(Value::as_str).unwrap_or_default().to_string()
}

/// One archive question, answered by the library.
fn answer(request: &str) -> Value {
    let parsed: Value = match serde_json::from_str(request) {
        Ok(value) => value,
        Err(error) => return json!({"ok": false, "error": format!("bad_request: {error}")}),
    };
    let op = parsed.get("op").and_then(Value::as_str).unwrap_or_default();
    let args = parsed.get("args").cloned().unwrap_or_else(|| json!({}));
    let month = text(&args, "month");
    match op {
        // The month due to be cut, and whether one named month is.
        "due" => match archive::ops::due(&Store, number(&args, "now_ms"), number(&args, "keep_days") as u32) {
            Ok(found) => json!({"ok": true, "month": found}),
            Err(error) => json!({"ok": false, "error": error}),
        },
        "is_due" => match archive::ops::is_due(&month, number(&args, "now_ms"), number(&args, "keep_days") as u32) {
            Ok(due) => json!({"ok": true, "due": due}),
            Err(error) => json!({"ok": false, "error": error}),
        },
        "restored_months" => match archive::ops::restored_months(&Store) {
            Ok(months) => json!({"ok": true, "months": months}),
            Err(error) => json!({"ok": false, "error": error}),
        },
        "unload" => match archive::ops::unload(&Store, &month, std::path::Path::new("")) {
            Ok(done) => json!({"ok": true, "unloaded": format!("{done:?}")}),
            Err(error) => json!({"ok": false, "error": error}),
        },
        // The pure name and time rules, so a caller outside the library asks the same code.
        "file_name" => json!({"ok": true, "name": archive::file_name(&month)}),
        "month_of_file" => json!({"ok": true, "month": archive::month_of_file(&text(&args, "name"))}),
        "expired" => json!({"ok": true, "expired": archive::expired(&month, number(&args, "now_ms"))}),
        "seal_context" => json!({"ok": true, "context": archive::seal_context(&month)}),
        "sha256_hex" => {
            let bytes = args.get("bytes_hex").and_then(Value::as_str).and_then(unhex).unwrap_or_default();
            json!({"ok": true, "sha256": archive::sha256_hex(&bytes)})
        }
        other => json!({"ok": false, "error": format!("unknown_op:{other}")}),
    }
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 {
        return None;
    }
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 2);
    let mut i = 0;
    while i < bytes.len() {
        let pair = std::str::from_utf8(&bytes[i..i + 2]).ok()?;
        out.push(u8::from_str_radix(pair, 16).ok()?);
        i += 2;
    }
    Some(out)
}

struct Component;

impl exports::wa::archive::control::Guest for Component {
    fn serve(request: String) -> String {
        answer(&request).to_string()
    }
}

export!(Component);
