//! WhatsApp linked-device client as a service component on `wa:kernel@0.2` (WASI 0.3).
//!
//! whatsapp-rust's protocol core, with everything that touches the outside world supplied by the
//! host: the websocket (`wa:kernel/websocket`, TLS in the host), HTTP (`wa:kernel/http`), the
//! recognizer (`wa:kernel/speech`), the clock (WASI) and stop (`wa:kernel/lifecycle`).
//!
//! Native async: there is no reactor and no polling loop over host I/O. The inbound websocket
//! frames are a `stream<list<u8>>` the socket task awaits, an exchange is one `http.send`, the
//! recognizer yields a segment stream plus one transcript future, and timers are
//! `wasi:clocks@0.3.0.wait-for`. The only executor left is the one the protocol crate insists on
//! (`Runtime::spawn`), and it is a plain set of futures joined with the main loop.
//!
//! Milestone 1: pair (by code when `pair_phone` is configured, else QR), connect, receive. The log
//! carries the pairing code, connection state and message metadata (chat, kind, id) - never content.
//! Store: store.rs - in-memory reads with write-through of durable state to the host (wa_kv);
//! a restart reconnects without pairing again.
//!
//! The crate is split so the decisions can be tested on the host: `queue` (freshness, retry, the
//! express lane), `posting` (allowlist gate, holds, chunks, edit pacing), `alerts` (own-chat log,
//! group titles) and `holds` (chats held until a revoke is proven) are pure logic with no host call
//! and no wasm target requirement; everything else (`guest`, `wasm`) needs the wasm32-wasip2
//! bindings and is compiled only for that target, so `cargo test` runs the decisions natively while
//! `cargo build --target wasm32-wasip2` builds the component.
pub mod alerts;
pub mod holds;
pub mod posting;
pub mod queue;

#[cfg(target_arch = "wasm32")]
mod store;

#[cfg(target_arch = "wasm32")]
wit_bindgen::generate!({
    world: "service-component",
    path: "../../../wit/kernel-v2",
    generate_all,
});

/// The service itself (host I/O, protocol, pipeline). Declared after `generate!` so the generated
/// `export!` macro is in textual scope inside it.
#[cfg(target_arch = "wasm32")]
mod guest;
