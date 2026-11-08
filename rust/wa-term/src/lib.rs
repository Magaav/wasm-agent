//! The console the operator and the agent share: raw mode, the editor line, panels, the ticker and
//! the transcript.
//!
//! - `terminal_editor`: raw mode, the editor, panels and their redraw.
//! - `selection`: what the pointer is on.
//! - `build_status`: the deploy's progress line.
//! - `tool_progress`: a long tool call's progress, on the same row (`docs/TOOL-PROGRESS.md`).
//! - `transcript`: the scrollback, its navigation and its keys.
//! - `scroll`: the fullscreen transcript on the alternate screen (`docs/TERMINAL.md`) - new, only
//!   used when a caller chooses it, so the inline console above is unchanged.
//!
//! Moved out of `wa-host` without rewriting logic. `wa-term` is a leaf: the host draws through it and
//! it imports nothing but `wa-host-support`, which is what makes a UI change cheap to build.
// The C ABI is a library API now: a console capability answers a Lua call through a raw `*mut LuaState` the
// interpreter owns for the duration of the call (`pub extern "C-unwind" fn ...(l: *mut LuaState)`). Marking
// those `unsafe fn` would only move the `unsafe` to every registration site without making them safer,
// so the lint is allowed once here, with the reason.
#![allow(clippy::not_unsafe_ptr_arg_deref)]
pub mod build_status;
pub mod scroll;
pub mod selection;
pub mod terminal_editor;
pub mod tool_progress;
pub mod transcript;
