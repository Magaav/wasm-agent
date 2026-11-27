//! The row a long tool call draws: ONE renderer, in `wa-tool-progress` (the crate both this program
//! and the node already depend on for the facts).
//!
//! MOVED OUT OF `wa-term` in the last slice of `wa-term-own-program`: the node draws this row itself
//! while the interpreter is blocked, so the renderer belongs where both sides can reach it - the
//! drawing crate keeps only a re-export, and there is exactly one implementation of every line.
pub use wa_tool_progress::render::{clip, content, current, detail, facts_now, line, Content};
