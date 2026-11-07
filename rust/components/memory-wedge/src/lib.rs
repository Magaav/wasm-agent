//! A fixture: the memory seam, wedged.
//!
//! Every exported function spins forever and never touches SQL. It exists so the deadline in
//! `rust/wa-kernel-runtime/src/memory_host.rs` is tested against a guest that really does not answer,
//! which is the only way to tell "the component is slow" from "the component is gone" — and so the
//! fallback in `lua/core/memory.lua` has something to fall back *from*.
//!
//! Never install it on a node: with no deadline it would take the turn with it.
// `generate_all`: the world imports `wa:kernel/sql`, and this fixture never calls it — the bindings
// exist so the component type matches, and no link is exercised before the spin.
wit_bindgen::generate!({ path: "../../../wit/memory", world: "memory-component", generate_all });

use crate::exports::wa::memory::memory::{Guest, RetentionPlan};
use crate::wa::memory::types::{Error as MError, Forgotten, Memory, MessageHit, Remembered, Session};

struct Wedge;

fn spin() -> ! {
    loop {
        std::hint::spin_loop();
    }
}

impl Guest for Wedge {
    fn remember(_content: String, _scope: Option<String>, _tags: Vec<String>, _id: Option<String>) -> Result<Remembered, MError> {
        spin()
    }
    fn recall(_text: String, _limit: u32, _scope: Option<String>, _exclusive: bool) -> Result<Vec<Memory>, MError> {
        spin()
    }
    fn forget(_id: String) -> Result<Forgotten, MError> {
        spin()
    }
    fn list(_scope: Option<String>, _limit: u32) -> Result<Vec<Memory>, MError> {
        spin()
    }
    fn search_messages(_text: String, _user_id: Option<String>, _limit: u32) -> Result<Vec<MessageHit>, MError> {
        spin()
    }
    fn sessions(_user_id: Option<String>, _limit: u32, _states: bool) -> Result<Vec<Session>, MError> {
        spin()
    }
    fn retention(_older_than_seconds: f64) -> Result<RetentionPlan, MError> {
        spin()
    }
}

export!(Wedge);
