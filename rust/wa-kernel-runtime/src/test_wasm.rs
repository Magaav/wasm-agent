//! Hand-built wasm artifacts for the tests that must not need a toolchain.
//!
//! The transactional install, the start-by-imports supervisor and the interface reader are all
//! decisions about an *artifact*: what it imports, whether its pin matches, whether a candidate that
//! starts is the one that runs. Proving them by building a real service component would put half the
//! suite behind `wasi-sdk` (and behind a fixture build the gate may skip), so the tests build the
//! smallest artifacts that exercise the same code: a core module with chosen imports and an optional
//! `_start`, encoded here by hand.
//!
//! These are *not* stand-ins for the runner: a module with no `_start` never becomes healthy, and the
//! tests use exactly that to prove a failed install leaves the old instance running.
#![cfg(test)]

/// Encode one section: id, LEB128 length, payload.
fn section(id: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = vec![id];
    out.extend(leb(payload.len() as u64));
    out.extend(payload);
    out
}

fn leb(mut value: u64) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let mut byte = (value & 0x7f) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if value == 0 {
            return out;
        }
    }
}

fn name(text: &str) -> Vec<u8> {
    let mut out = leb(text.len() as u64);
    out.extend(text.as_bytes());
    out
}

/// A `wasm32-wasip1`-shaped core module: one imported function per `(module, field)`, an exported
/// `_start` when `start` is set (the module then runs and returns at once), otherwise nothing to run.
///
/// An imported function is what makes the import list carry the module name - exactly what a wasip1
/// service's `wa_sock.connect` looks like to `Module::imports()`.
pub fn core_module(imports: &[(&str, &str)], start: bool) -> Vec<u8> {
    let mut out = b"\0asm\x01\0\0\0".to_vec();
    // type: one `() -> ()` function.
    out.extend(section(1, &[0x01, 0x60, 0x00, 0x00]));
    if !imports.is_empty() {
        let mut body = leb(imports.len() as u64);
        for (module, field) in imports {
            body.extend(name(module));
            body.extend(name(field));
            body.push(0x00); // func
            body.extend(leb(0)); // type index 0
        }
        out.extend(section(2, &body));
    }
    let defined = usize::from(start);
    if start {
        out.extend(section(3, &[0x01, 0x00])); // one function, type 0
        let mut exports = leb(1);
        exports.extend(name("_start"));
        exports.push(0x00); // func
        exports.extend(leb(imports.len() as u64)); // the index after the imports
        out.extend(section(7, &exports));
        // One empty body: no locals, `end`.
        out.extend(section(10, &[0x01, 0x02, 0x00, 0x0b]));
    }
    let _ = defined;
    out
}

/// A module whose `_start` never returns: `loop { br 0 }`. It costs nothing but wasm instructions, so
/// it is the one artifact that can prove the CPU budget traps a guest without the test waiting for a
/// real workload - the trap comes from the epoch deadline, which is what `limits.cpu_ms` sets.
pub fn spin_module() -> Vec<u8> {
    let mut out = b"\0asm\x01\0\0\0".to_vec();
    out.extend(section(1, &[0x01, 0x60, 0x00, 0x00])); // one () -> () type
    out.extend(section(3, &[0x01, 0x00])); // one function, type 0
    let mut exports = vec![0x01];
    exports.extend(name("_start"));
    exports.push(0x00);
    exports.push(0x00); // function index 0
    out.extend(section(7, &exports));
    // One body: no locals, `loop`, `br 0`, `end`, `end`.
    out.extend(section(10, &[0x01, 0x07, 0x00, 0x03, 0x40, 0x0c, 0x00, 0x0b, 0x0b]));
    out
}

/// A module that imports nothing and never exports anything to run: the "instance that starts and
/// then can never report health" a rollback test needs. It instantiates, so the runner's refusal is
/// "there is nothing to run" rather than a link error - which is what makes it a fair stand-in for a
/// component whose health report never arrives.
pub fn silent_module(tag: u32) -> Vec<u8> {
    // The tag rides in a custom section so two builds are different bytes with different pins, which
    // is what an upgrade needs (same name, other artifact).
    let mut bytes = core_module(&[], false);
    let mut payload = name("wa-test");
    payload.extend(leb(tag as u64));
    bytes.extend(section(0, &payload));
    bytes
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hand_built_module_is_a_module_wasmtime_parses() {
        // The one thing that must not rot silently: these bytes are a valid module. `imports::of_bytes`
        // asserts the rest (imports, exports, contract) from the parser's own view.
        let plain = core_module(&[], false);
        assert_eq!(&plain[..8], b"\0asm\x01\0\0\0");
        let with_start = core_module(&[("wa_sock", "connect")], true);
        assert!(with_start.len() > plain.len());
        assert_ne!(silent_module(1), silent_module(2), "two builds are different pins");
        assert!(spin_module().len() > 30, "the spinning module is a real module");
        assert_eq!(silent_module(1), silent_module(1), "and the same build is the same bytes");
    }
}
