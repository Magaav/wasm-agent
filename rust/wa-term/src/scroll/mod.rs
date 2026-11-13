//! The fullscreen transcript: `wa chat` on the alternate screen, scrolled by the reader.
//!
//! pi's console (`docs/keybindings.md` in the pi coding agent) is one full-screen transcript with the
//! draft pinned under it: the agent keeps streaming into it, the reader can leave the bottom and read
//! back, and the output that arrived meanwhile is counted on one row instead of dragging the view.
//! This is that, on top of what this repo already has - `crate::transcript` for wrapping and
//! `crate::terminal_editor` for the input box - and nothing about the inline console changes:
//!
//! - `settings`: the node's knobs (`WA_TUI*`) and the fallback decision (`--inline`, `WA_TUI=inline`,
//!   a pipe, `WA_TUI_FULLSCREEN=off`).
//! - `keys`: which keys belong to the chat. Everything else is forwarded to the input editor unchanged.
//! - `bar`: the scrollbar as a model - one continuous track, the thumb, hover, and the arithmetic a
//!   click and a drag use (pi's rules; both transcripts draw from it).
//! - `chat`: the blocks, their folds, the scroll position, the new-lines marker, the scrollbar.
//! - `screen`: the alternate screen, the layout that leaves the editor its rows, and the restore paths.
//! - `vt`: a terminal in memory, so the tests assert on the screen a reader would see.
//!
//! Keys, as they ship: PageUp/PageDown page; Ctrl+Home is the top; Ctrl+End is the bottom *and*
//! follow; Ctrl+O folds tool output; Ctrl+T folds thinking. Half-page and line scrolling exist and are
//! unbound until an operator binds them (`WA_TUI_KEYS=alt+v=half-page-down,ctrl+u=line-up`), because
//! those chords are the draft's until someone decides otherwise. The wheel scrolls
//! `WA_TUI_WHEEL_LINES` rows (`auto` = three, the inline console's step) and the scrollbar
//! (`auto` | `always` | `hidden`) takes the right column: click it to jump, drag the thumb to scroll,
//! and it thickens under the pointer (`SGR` reports, `bar`).
//!
//! Wiring it to the process is the caller's: `Console::frame` draws the whole screen and takes the
//! editor, so the host's reader thread (which already owns the keys and the editor) calls `feed`,
//! `write` and `frame` where it calls the inline transcript today, with `Guard::arm` around the
//! session and `install_panic_restore` once at startup. Until that call site exists nothing here runs,
//! which is why the inline console is unchanged byte for byte.
pub mod bar;
pub mod chat;
pub mod keys;
pub mod screen;
pub mod settings;
pub mod vt;

pub use bar::Bar;
pub use chat::{Chat, Kind};
pub use keys::{Decoder, Key};
pub use screen::{Console, Guard, Handled, PanicRestore};
pub use settings::{Action, Mode, Scrollbar, Settings, Wheel};

#[cfg(test)]
mod render;
