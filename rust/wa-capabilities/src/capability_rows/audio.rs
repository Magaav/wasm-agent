//! The file-backed ear and mouth, confined to the declared audio root; the voice itself is the voice
//! WASM plugin. The handler is in crate::audio.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    // The contract is one entry because it is one capability with two calls: `capture` (the ear)
    // and `play` (the mouth). Voice itself is the `voice` WASM plugin; this is only the transport.
    plain!("audio", Device, crate::audio::capability, "The file-backed ear and mouth: capture PCM chunks from a WAV source, or play PCM into a WAV sink, both confined to the declared audio root"),
];
