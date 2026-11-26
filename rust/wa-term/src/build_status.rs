//! The build loader's row: ONE renderer, in `wa-tool-progress` (the crate both the program and the
//! node already depend on).
//!
//! MOVED OUT OF `wa-term` in the last slice of `wa-term-own-program`; this module is the re-export, so
//! every `crate::build_status::…` path in this crate keeps working.
pub use wa_tool_progress::build::*;
